import AppKit
import UniformTypeIdentifiers

/// Paths survive queue persistence. The session identity is checked before a drag becomes a job.
struct DeviceDownloadSource {
    let sessionID: UUID
    let storageID: UInt32
    let storageName: String
    let folderPath: [String]
    let name: String

    func job(to destination: URL) -> TransferJob {
        TransferJob(
            direction: .download, displayName: name, storageID: storageID,
            storageName: storageName, folderPath: folderPath, itemName: name,
            localURLPaths: nil, localDestinationPath: destination.path
        )
    }
}

struct DeviceDownloadDrag {
    let sequence: Int
    let sources: [DeviceDownloadSource]

    func jobs(sessionID: UUID, to destination: URL) -> [TransferJob]? {
        guard sources.allSatisfy({ $0.sessionID == sessionID }) else { return nil }
        return sources.map { $0.job(to: destination) }
    }
}

/// Only Finder's file promise goes on the pasteboard. The local pane uses the active drag session.
final class DeviceFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    let name: String
    private let writeContents: @MainActor (URL) async throws -> Void

    init(name: String, isFolder: Bool, writeContents: @escaping @MainActor (URL) async throws -> Void) {
        self.name = name
        self.writeContents = writeContents
        super.init()
        let type = UTType(filenameExtension: (name as NSString).pathExtension, conformingTo: .data) ?? .data
        fileType = isFolder ? UTType.folder.identifier : type.identifier
        delegate = self
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                try await write(to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    @MainActor
    func write(to destination: URL) async throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".aft-\(UUID()).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await writeContents(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}
