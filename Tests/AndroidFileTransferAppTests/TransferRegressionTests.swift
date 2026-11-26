import AppKit
import XCTest
@testable import AndroidFileTransferApp

@MainActor
final class TransferRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func job(_ name: String, in folder: URL) -> TransferJob {
        DeviceDownloadSource(sessionID: UUID(), storageID: 1, storageName: "Phone",
                             folderPath: [], name: name).job(to: folder)
    }

    private func item(_ name: String, size: Int64?, folder: Bool = false) -> BrowserItem {
        BrowserItem(id: name, name: name, isFolder: folder, size: size, date: nil,
                    handle: 10, url: nil, isSymbolicLink: false)
    }

    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut(description: description) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct WaitTimedOut: Error, CustomStringConvertible { let description: String }

    func testDeviceActionDefersWorkerAndCancelDoesNotInterruptPreview() async throws {
        let folder = try directory()
        let queue = TransferQueue(store: TransferQueueStore(url: folder.appendingPathComponent("queue")))
        var starts = 0
        var aborts = 0
        queue.runner = { _ in starts += 1 }
        queue.onAbortRequested = { aborts += 1 }
        XCTAssertTrue(queue.beginDeviceAction())
        queue.enqueue([job("photo", in: folder)])
        queue.cancelCurrent()
        XCTAssertNil(queue.currentJobID)
        XCTAssertEqual(queue.jobs.first?.state, .pending)
        XCTAssertEqual(aborts, 0)
        queue.endDeviceAction()
        try await waitFor("deferred job") { queue.jobs.first?.state == .completed }
        XCTAssertEqual(starts, 1)
    }

    func testEarlyResumeAndRetryCannotChangeStoppingJob() async throws {
        let folder = try directory()
        let queue = TransferQueue(store: TransferQueueStore(url: folder.appendingPathComponent("queue")))
        let first = job("first", in: folder), second = job("second", in: folder)
        var retryable = job("failed", in: folder)
        retryable.state = .failed
        var cleanup: CheckedContinuation<Void, Never>?
        var firstRun = true
        queue.runner = { _ in
            if firstRun {
                firstRun = false
                await withCheckedContinuation { cleanup = $0 }
                try Task.checkCancellation()
            }
        }
        queue.enqueue([first, second, retryable])
        try await waitFor("started first") { cleanup != nil }
        queue.pause()
        queue.resume()
        queue.retry(retryable.id)
        XCTAssertTrue(queue.isAborting)
        XCTAssertFalse(queue.canResume)
        XCTAssertEqual(queue.jobs[2].state, .failed)
        cleanup?.resume()
        try await waitFor("finished cleanup") { !queue.isProcessing }
        XCTAssertEqual(queue.jobs.map(\.state), [.paused, .pending, .failed])
        queue.remove(second.id)
        XCTAssertTrue(queue.hasPausedJobs)
        XCTAssertTrue(queue.canResume)
        queue.resume()
        try await waitFor("resumed first") { queue.jobs[0].state == .completed }
    }

    func testRestoredDestinationAndLegacyDefault() throws {
        let folder = try directory()
        let store = TransferQueueStore(url: folder.appendingPathComponent("queue"))
        let model = AppModel(queueStore: store, localDirectory: folder)
        let dest = folder.appendingPathComponent("removable", isDirectory: true)
        let original = job("photo", in: dest)
        store.save([original])
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertThrowsError(try model.downloadFolder(for: saved))
        try Data().write(to: dest)
        XCTAssertThrowsError(try model.downloadFolder(for: saved))
        try FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        XCTAssertEqual(try model.downloadFolder(for: saved).path, dest.path)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields.removeValue(forKey: "localDestinationPath")
        let legacy = try JSONDecoder().decode(TransferJob.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(try model.downloadFolder(for: legacy), FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
    }

    func testPreviewCachePublishesCompleteFilesInSeparateSessions() async throws {
        let folder = try directory(), id = UUID(), other = UUID()
        let cache = DevicePreviewCache(directory: folder)
        let entry = item("photo.jpg", size: 4)
        let first = try await cache.file(for: entry, handle: 12, sessionID: id) { staging in
            try Data("a".utf8).write(to: staging)
            let final = staging.deletingLastPathComponent().appendingPathComponent(entry.name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            try Data("aaaa".utf8).write(to: staging)
        }
        let hit = try await cache.file(for: entry, handle: 12, sessionID: id) { _ in XCTFail("Unexpected download") }
        XCTAssertEqual(hit, first)
        do {
            _ = try await cache.file(for: entry, handle: 12, sessionID: other) { staging in
                try Data("b".utf8).write(to: staging)
                throw CancellationError()
            }
            XCTFail("Download should throw")
        } catch is CancellationError {}
        let second = try await cache.file(for: entry, handle: 12, sessionID: other) { try Data("bbbb".utf8).write(to: $0) }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("aaaa".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("bbbb".utf8))
    }

    func testDeviceDragQueuesCapturedRowsAndRejectsReconnectedSession() throws {
        let folder = try directory(), session = UUID()
        let sources = ["image.jpg", "Trip"].map {
            DeviceDownloadSource(sessionID: session, storageID: 3, storageName: "SD", folderPath: ["Pictures"], name: $0)
        }
        let drag = DeviceDownloadDrag(sequence: 1, sources: sources)
        XCTAssertNil(drag.jobs(sessionID: UUID(), to: folder))
        let jobs = try XCTUnwrap(drag.jobs(sessionID: session, to: folder))
        XCTAssertEqual(jobs.map(\.itemName), ["image.jpg", "Trip"])
        XCTAssertTrue(jobs.allSatisfy { $0.storageID == 3 && $0.folderPath == ["Pictures"] && $0.localDestinationPath == folder.path })
        let model = AppModel(queueStore: TransferQueueStore(url: folder.appendingPathComponent("queue")), localDirectory: folder)
        XCTAssertFalse(model.acceptDeviceDrop(sequence: 1))
    }

    func testFilePromisePublishesOnlyCompleteContentsAtReceiverURL() async throws {
        let folder = try directory(), bytes = Data([0, 1, 2, 255])
        let destination = folder.appendingPathComponent("renamed-by-receiver.bin")
        let promise = DeviceFilePromise(name: "original.bin", isFolder: false) { temporary in
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try bytes.write(to: temporary)
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let advertised = Set(promise.writableTypes(for: pasteboard).map(\.rawValue))
        XCTAssertFalse(advertised.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes))
        XCTAssertEqual(promise.filePromiseProvider(promise, fileNameForType: promise.fileType), "original.bin")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            promise.filePromiseProvider(promise, writePromiseTo: destination) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let partial = DeviceFilePromise(name: "album", isFolder: true) { temporary in
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            try bytes.write(to: temporary.appendingPathComponent("photo"))
            throw CancellationError()
        }
        do {
            try await partial.write(to: folder.appendingPathComponent("album"))
            XCTFail("Interrupted folder published")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [destination.lastPathComponent])
    }

    func testMixedSelectionAndOversizedFileSort() {
        let folder = item("folder", size: nil, folder: true)
        let small = item("small", size: 7), large = item("large", size: nil)
        let sort = KeyPathComparator(\BrowserItem.sortSize)
        let device = DeviceBrowser(manager: DeviceManager())
        device.items = BrowserItem.sorted([large, folder, small], using: [sort])
        XCTAssertEqual(device.items.map(\.id), [folder.id, small.id, large.id])
        device.selection = [folder.id, large.id]
        XCTAssertEqual(device.previewItem?.id, large.id)
        device.selection = [folder.id]
        XCTAssertNil(device.previewItem)
    }

    func testNewLabelsInEnglishAndChinese() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let l10n = Localization(defaults: defaults)
        for language: AppLanguage in [.english, .simplifiedChinese] {
            l10n.language = language
            for key in ["header.uploadToPhone", "header.downloadToMac", "pane.phone", "context.showInFinder",
                        "empty.folder", "sidebar.connecting", "transfer.showQueue", "alerts.expiredDrag"] {
                XCTAssertNotEqual(l10n.t(key), key)
            }
            for key in ["header.uploadHelp", "header.downloadHelp", "drop.upload", "drop.download", "transfer.savedTo", "alerts.downloadDestination"] {
                XCTAssertTrue(l10n.t(key, "TestFolder").contains("TestFolder"))
            }
            for key in ["transfer.waiting", "transfer.queued"] { XCTAssertTrue(l10n.t(key, 17).contains("17")) }
            let capacity = l10n.t("sidebar.capacity", "FREE", "TOTAL")
            XCTAssertTrue(capacity.contains("FREE") && capacity.contains("TOTAL"))
        }
    }
}
