import AppKit
import Foundation
import AndroidFileTransferKit
import Observation

@MainActor
@Observable
final class AppModel {
    let l10n = Localization()
    let devices = DeviceManager()
    let local: LocalBrowser
    let device: DeviceBrowser
    let transfer: TransferStatus
    let queue: TransferQueue
    private let previewCache: DevicePreviewCache
    private let showPreview: @MainActor ([URL]) -> Void

    var alertMessage: String?
    var pendingDelete: DeviceDeleteRequest?
    var conflictRequest: ConflictRequest?
    private(set) var deviceDrag: DeviceDownloadDrag?

    private var transferTask: Task<Void, Never>?
    private var conflictContinuation: CheckedContinuation<ConflictResolution, Never>?
    private var abortCurrentTransferOnCancel = false
    private var lastFailedDownloadItems: [BrowserItem]?
    private var lastFailedUploadItems: [BrowserItem]?

    init(queueStore: TransferQueueStore = TransferQueueStore(), localDirectory: URL? = nil,
         previewDirectory: URL = FileManager.default.temporaryDirectory,
         showPreview: @escaping @MainActor ([URL]) -> Void = { QuickLookController.shared.show(urls: $0) }) {
        queue = TransferQueue(store: queueStore)
        local = LocalBrowser(directory: localDirectory)
        previewCache = DevicePreviewCache(directory: previewDirectory)
        self.showPreview = showPreview
        device = DeviceBrowser(manager: devices)
        transfer = TransferStatus(l10n: l10n)

        queue.runner = { [weak self] job in
            guard let self else { return }
            try await self.executeQueuedJob(job)
        }
        queue.onAbortRequested = { [weak self] in
            self?.resolveConflict(.cancel)
        }
    }

    func start() {
        devices.start()
    }

    func stop() {
        transferTask?.cancel()
        devices.stop()
    }

    // Downloads and uploads go through the queue, so they can be enqueued
    // while another transfer is running.
    var canDownload: Bool {
        devices.isConnected
            && device.selectedItems().contains { $0.handle != nil }
    }

    var canUpload: Bool {
        devices.isConnected
            && device.storage != nil
            && !local.selectedItems().isEmpty
    }

    var canDeleteDevice: Bool {
        queue.canBeginDeviceAction
            && devices.isConnected
            && device.storage != nil
            && !device.selectedItems().isEmpty
    }

    var canPreviewDeviceSelection: Bool {
        queue.canBeginDeviceAction && device.previewItem != nil
    }

    private var activeFinderExports = 0
    var isBusyForUpdate: Bool { !queue.canBeginDeviceAction || activeFinderExports > 0 || transfer.isActive }

    var downloadDestination: URL { local.currentURL }

    private func downloadSource(for item: BrowserItem) -> DeviceDownloadSource? {
        guard item.handle != nil, let session = devices.session, let storage = device.storage else { return nil }
        return DeviceDownloadSource(sessionID: session.instanceID, storageID: storage.id,
                                    storageName: storage.name, folderPath: device.path.map(\.name), name: item.name)
    }

    func downloadSelected() {
        guard device.storage != nil else {
            alertMessage = l10n.t("alerts.noStorage")
            return
        }
        let jobs = device.selectedItems().compactMap(downloadSource).map { $0.job(to: downloadDestination) }
        guard !jobs.isEmpty else {
            alertMessage = l10n.t("alerts.selectPhone")
            return
        }
        queue.enqueue(jobs)
    }

    func beginDeviceDrag(sequence: Int, items: [BrowserItem]) {
        let sources = items.compactMap(downloadSource)
        guard !sources.isEmpty, sources.count == items.count else {
            deviceDrag = nil
            return
        }
        deviceDrag = DeviceDownloadDrag(sequence: sequence, sources: sources)
    }

    func endDeviceDrag(sequence: Int) {
        if deviceDrag?.sequence == sequence { deviceDrag = nil }
    }

    func acceptDeviceDrop(sequence: Int) -> Bool {
        guard let drag = deviceDrag, drag.sequence == sequence else { return false }
        guard let session = devices.session, let jobs = drag.jobs(sessionID: session.instanceID, to: downloadDestination) else {
            alertMessage = l10n.t("alerts.expiredDrag")
            return false
        }
        queue.enqueue(jobs)
        return true
    }

    func uploadSelected() {
        enqueueUploads(items: local.selectedItems())
    }

    func uploadDroppedURLs(_ urls: [URL]) {
        enqueueUploads(items: urls.compactMap { BrowserItem.from(url: $0) })
    }

    private func enqueueUploads(items: [BrowserItem]) {
        guard let storage = device.storage else {
            alertMessage = l10n.t("alerts.noStorage")
            return
        }
        let filtered = items.filter { !$0.isSymbolicLink && $0.url != nil }
        guard !filtered.isEmpty else {
            alertMessage = items.isEmpty
                ? l10n.t("alerts.selectLocal")
                : l10n.t("alerts.symlink")
            return
        }

        let folderPath = device.path.map(\.name)
        let jobs = filtered.map { item in
            TransferJob(
                direction: .upload,
                displayName: item.name,
                storageID: storage.id,
                storageName: storage.name,
                folderPath: folderPath,
                itemName: nil,
                localURLPaths: [item.url!.path]
            )
        }
        queue.enqueue(jobs)
    }

    func cancelTransfer() {
        queue.cancelCurrent()
    }

    func pauseTransfer() {
        queue.pause()
    }

    func resumeTransfer() {
        queue.resume()
    }

    var canRetryLastTransfer: Bool {
        queue.jobs.contains {
            $0.state == .failed || $0.state == .canceled || $0.state == .paused
        }
    }

    func retryLastTransfer() {
        queue.retryLastFailed()
    }

    func dismissTransferError() {
        transfer.dismissError()
    }

    // MARK: - Batch delete

    func requestDeleteDeviceSelection() {
        guard let storage = device.storage else {
            alertMessage = l10n.t("alerts.noStorage")
            return
        }
        let items = device.selectedItems()
        guard !items.isEmpty else {
            alertMessage = l10n.t("alerts.selectPhone")
            return
        }
        pendingDelete = DeviceDeleteRequest(items: items, storageID: storage.id)
    }

    func confirmDeleteDeviceSelection() {
        guard let request = pendingDelete else { return }
        pendingDelete = nil
        guard queue.beginDeviceAction() else {
            alertMessage = l10n.t("alerts.transferRunning")
            return
        }
        abortCurrentTransferOnCancel = false
        transferTask = Task {
            defer { queue.endDeviceAction() }
            await performDelete(request)
        }
    }

    func cancelDeleteDeviceSelection() {
        pendingDelete = nil
    }

    private func performDelete(_ request: DeviceDeleteRequest) async {
        defer {
            transferTask = nil
            abortCurrentTransferOnCancel = false
        }

        guard let session = devices.session else {
            alertMessage = l10n.t("alerts.noDevice")
            return
        }

        transfer.start(title: l10n.t("transfer.deleting"), total: nil)
        do {
            for item in request.items {
                try Task.checkCancellation()
                guard let handle = item.handle else { continue }
                if item.isFolder {
                    try await deleteDeviceFolder(
                        handle: handle,
                        storageID: request.storageID,
                        session: session
                    )
                } else {
                    try await session.delete(handle: handle)
                }
            }

            transfer.finish(detail: l10n.t("transfer.deleted"))
            device.selection = []
            await device.reload()
        } catch is CancellationError {
            transfer.canceled()
        } catch {
            transfer.fail(error)
            alertMessage = error.localizedDescription
        }
    }

    private func deleteDeviceFolder(
        handle: UInt32,
        storageID: UInt32,
        session: MTPDeviceSession
    ) async throws {
        try Task.checkCancellation()
        let children = try await session.children(of: handle, storageID: storageID)
        for child in children {
            if child.info.isFolder {
                try await deleteDeviceFolder(
                    handle: child.handle,
                    storageID: storageID,
                    session: session
                )
            } else {
                try await session.delete(handle: child.handle)
            }
        }
        try await session.delete(handle: handle)
    }

    // MARK: - Conflict resolution

    func resolveConflict(_ resolution: ConflictResolution) {
        conflictRequest = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: resolution)
    }

    private func askConflictResolution(names: [String]) async -> ConflictResolution {
        guard !Task.isCancelled else { return .cancel }
        guard !names.isEmpty else { return .keepBoth }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            conflictRequest = ConflictRequest(
                names: Array(names.prefix(6)),
                totalCount: names.count
            )
        }
    }

    func filePromise(for item: BrowserItem) -> DeviceFilePromise? {
        guard let handle = item.handle, let session = devices.session, let storage = device.storage else { return nil }
        return DeviceFilePromise(name: item.name, isFolder: item.isFolder) { destination in
            guard self.devices.session === session else { throw MTPError.notOpen }
            self.activeFinderExports += 1
            defer { self.activeFinderExports -= 1 }
            if item.isFolder {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try await self.downloadFolderTree(handle: handle, to: destination, session: session, storageID: storage.id)
            } else {
                try await session.download(handle: handle, to: destination)
            }
        }
    }

    private func downloadFolderTree(
        handle: UInt32,
        to folder: URL,
        session: MTPDeviceSession,
        storageID: UInt32
    ) async throws {
        let children = try await session.children(of: handle, storageID: storageID)
        for child in children {
            if child.info.isFolder {
                let subfolder = folder.appendingPathComponent(
                    child.info.filename,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: subfolder,
                    withIntermediateDirectories: true
                )
                try await downloadFolderTree(
                    handle: child.handle,
                    to: subfolder,
                    session: session,
                    storageID: storageID
                )
            } else {
                let destination = folder.appendingPathComponent(child.info.filename)
                try await session.download(handle: child.handle, to: destination)
            }
        }
    }

    func quickLookSelection(preferDevice: Bool = false) {
        if !preferDevice, let url = local.selectedItems().first?.url {
            showPreview([url])
            return
        }
        guard let session = devices.session, let item = device.previewItem,
              let handle = item.handle, queue.beginDeviceAction() else { return }
        transferTask = Task {
            defer {
                transferTask = nil
                queue.endDeviceAction()
            }
            transfer.start(title: l10n.t("transfer.preparing", item.name), total: item.size)
            do {
                let url = try await previewCache.file(for: item, handle: handle, sessionID: session.instanceID) {
                    try await session.download(handle: handle, to: $0)
                }
                guard devices.session === session else { throw CancellationError() }
                transfer.finish(detail: item.name)
                showPreview([url])
            } catch is CancellationError {
                transfer.canceled()
            } catch {
                transfer.fail(error)
                alertMessage = error.localizedDescription
            }
        }
    }

    func refreshDevice() {
        Task {
            await devices.refresh()
            await device.selectFirstStorageIfNeeded()
            await device.reload()
        }
    }

    func reconnectDevice() {
        Task {
            await devices.reconnect()
            await device.selectFirstStorageIfNeeded()
            await device.reload()
        }
    }

    // MARK: - Persistent queue runner

    private var downloadsDirectory: URL {
        FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func resolveStorage(for job: TransferJob) -> StorageItem? {
        if let id = job.storageID,
           let storage = devices.storages.first(where: { $0.id == id }) {
            return storage
        }
        if let name = job.storageName {
            return devices.storages.first(where: { $0.name == name })
        }
        return devices.storages.first
    }

    private func resolveFolderPath(
        _ path: [String],
        storageID: UInt32,
        session: MTPDeviceSession
    ) async throws -> UInt32 {
        var handle: UInt32 = 0xFFFF_FFFF
        for name in path {
            let children = try await session.children(of: handle, storageID: storageID)
            guard let child = children.first(where: {
                $0.info.isFolder && $0.info.filename == name
            }) else {
                throw MTPError.invalidResponse("folder not found: \(name)")
            }
            handle = child.handle
        }
        return handle
    }

    private func resolveDownloadItem(
        job: TransferJob,
        storage: StorageItem,
        session: MTPDeviceSession
    ) async throws -> BrowserItem {
        let parent = try await resolveFolderPath(
            job.folderPath,
            storageID: storage.id,
            session: session
        )
        let children = try await session.children(of: parent, storageID: storage.id)
        guard let name = job.itemName,
              let child = children.first(where: { $0.info.filename == name })
        else {
            throw MTPError.invalidResponse("object not found: \(job.itemName ?? "?")")
        }

        return BrowserItem(
            id: "mtp-\(child.handle)",
            name: child.info.filename,
            isFolder: child.info.isFolder,
            size: child.info.size.map { Int64(clamping: $0) },
            date: child.info.modificationDate.date,
            handle: child.handle,
            url: nil,
            isSymbolicLink: false
        )
    }

    private func resolveUploadItems(job: TransferJob) throws -> [BrowserItem] {
        guard let paths = job.localURLPaths, !paths.isEmpty else {
            throw MTPError.localFile("no local source for \(job.displayName)")
        }
        return try paths.map { path in
            let url = URL(fileURLWithPath: path)
            guard let item = BrowserItem.from(url: url), !item.isSymbolicLink else {
                throw MTPError.localFile("cannot read \(path)")
            }
            return item
        }
    }

    private func executeQueuedJob(_ job: TransferJob) async throws {
        guard let session = devices.session else {
            transfer.fail(MTPError.notOpen)
            throw MTPError.notOpen
        }
        do {
            try await session.withCancellableOperation {
                try await self.runQueuedJob(job, session: session)
            }
            if job.direction == .upload, devices.session === session {
                // Listing the pane is separate from the already committed upload.
                await device.reload()
            }
        } catch {
            if queue.isAborting || error is CancellationError {
                transfer.canceled()
                if queue.isAborting, !(await session.isSessionOpen), devices.session === session {
                    // Recovery must outlive the canceled job task. The worker waits for it.
                    await Task { await self.recoverAfterAbortedTransfer() }.value
                }
            } else {
                transfer.fail(error)
            }
            throw error
        }
    }

    func downloadFolder(for job: TransferJob) throws -> URL {
        guard let path = job.localDestinationPath else { return downloadsDirectory }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isWritableFile(atPath: path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: l10n.t("alerts.downloadDestination", path)])
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func runQueuedJob(_ job: TransferJob, session: MTPDeviceSession) async throws {
        guard let storage = resolveStorage(for: job) else {
            throw MTPError.invalidResponse("storage not found")
        }

        queue.setProgress(job.id, progress: 0)

        switch job.direction {
        case .download:
            transfer.start(title: l10n.t("transfer.preparing", job.displayName), total: nil)
            let downloads = try downloadFolder(for: job)
            let item = try await resolveDownloadItem(
                job: job,
                storage: storage,
                session: session
            )
            let destination = downloads.appendingPathComponent(item.name)

            let resolution: ConflictResolution
            if FileManager.default.fileExists(atPath: destination.path) {
                resolution = await askConflictResolution(names: [item.name])
                if resolution == .cancel {
                    throw CancellationError()
                }
            } else {
                resolution = .keepBoth
            }

            let plan = try await makeDownloadPlan(
                for: item,
                session: session,
                storageID: storage.id
            )

            _ = try downloadFolder(for: job)
            try await executeDownload(
                plan: plan,
                session: session,
                downloads: downloads,
                conflictResolution: resolution
            ) { progress in
                Task { @MainActor in
                    self.queue.setProgress(job.id, progress: progress)
                }
            }
            if local.currentURL.standardizedFileURL == downloads.standardizedFileURL {
                local.reload()
            }

        case .upload:
            transfer.start(title: l10n.t("transfer.preparing", job.displayName), total: nil)
            let items = try resolveUploadItems(job: job)
            let parent = try await resolveFolderPath(
                job.folderPath,
                storageID: storage.id,
                session: session
            )
            let children = try await session.children(of: parent, storageID: storage.id)
            let existingItems = children.map { child in
                BrowserItem(
                    id: "mtp-\(child.handle)",
                    name: child.info.filename,
                    isFolder: child.info.isFolder,
                    size: child.info.size.map { Int64(clamping: $0) },
                    date: child.info.modificationDate.date,
                    handle: child.handle,
                    url: nil,
                    isSymbolicLink: false
                )
            }
            let existingNames = Set(existingItems.map(\.name))
            let conflictNames = items.map(\.name).filter { existingNames.contains($0) }

            let resolution: ConflictResolution
            if conflictNames.isEmpty {
                resolution = .keepBoth
            } else {
                resolution = await askConflictResolution(names: conflictNames)
                if resolution == .cancel {
                    throw CancellationError()
                }
            }

            var usedNames = existingNames
            for item in items {
                let plan = try makeUploadPlan(for: item)
                let rootName = try await executeUpload(
                    plan: plan,
                    session: session,
                    storageID: storage.id,
                    existingNames: usedNames,
                    conflictResolution: resolution,
                    destinationParent: parent,
                    existingItems: existingItems
                ) { progress in
                    Task { @MainActor in
                        self.queue.setProgress(job.id, progress: progress)
                    }
                }
                usedNames.insert(rootName)
            }
        }
    }

    // MARK: - Download

    private func performDownload(items: [BrowserItem]) async {
        defer {
            transferTask = nil
            abortCurrentTransferOnCancel = false
        }

        guard let session = devices.session, let storage = device.storage else {
            alertMessage = l10n.t("alerts.noStorage")
            return
        }
        guard !items.isEmpty else {
            alertMessage = l10n.t("alerts.selectPhone")
            return
        }

        let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        let conflictNames = items.compactMap { item -> String? in
            let destination = downloads.appendingPathComponent(item.name)
            return FileManager.default.fileExists(atPath: destination.path) ? item.name : nil
        }
        let conflictResolution: ConflictResolution
        if conflictNames.isEmpty {
            conflictResolution = .keepBoth
        } else {
            conflictResolution = await askConflictResolution(names: conflictNames)
            if conflictResolution == .cancel {
                transfer.canceled()
                return
            }
        }

        do {
            for item in items {
                await transfer.waitIfPaused()
                try Task.checkCancellation()
                transfer.start(title: l10n.t("transfer.preparing", item.name), total: nil)
                let plan = try await makeDownloadPlan(
                    for: item,
                    session: session,
                    storageID: storage.id
                )
                try await executeDownload(
                    plan: plan,
                    session: session,
                    downloads: downloads,
                    conflictResolution: conflictResolution
                )
            }

            transfer.finish(detail: l10n.t("transfer.savedDownloads"))
            if local.currentURL.standardizedFileURL == downloads.standardizedFileURL {
                local.reload()
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                transfer.canceled()
                await recoverAfterAbortedTransfer()
            } else {
                lastFailedDownloadItems = items
                transfer.fail(error)
                alertMessage = error.localizedDescription
            }
        }
    }

    private func recoverAfterAbortedTransfer() async {
        device.clear()
        await devices.disconnect()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await devices.refresh()

        if !devices.isConnected {
            // A mid-transfer abort can leave the phone's MTP server wedged.
            // Reset the parent USB device so it re-enumerates, then wait for
            // the IOKit monitor (or a manual refresh) to reconnect.
            devices.resetUSBForRecovery()
            for _ in 0 ..< 12 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if devices.isConnected {
                    break
                }
                await devices.refresh()
            }
        }

        await device.selectFirstStorageIfNeeded()
        await device.reload()
    }

    private func makeDownloadPlan(
        for item: BrowserItem,
        session: MTPDeviceSession,
        storageID: UInt32
    ) async throws -> TransferPlan {
        guard let handle = item.handle else {
            throw MTPError.invalidResponse("missing object handle for \(item.name)")
        }

        if !item.isFolder {
            return TransferPlan(
                rootName: item.name,
                isDirectory: false,
                directories: [],
                files: [
                    TransferFile(
                        name: item.name,
                        relativeDirectory: "",
                        size: item.size,
                        deviceHandle: handle,
                        localURL: nil
                    ),
                ],
                totalBytes: item.size
            )
        }

        var directories: [String] = []
        var files: [TransferFile] = []
        var totalBytes: Int64? = 0
        try await scanDeviceFolder(
            handle: handle,
            relativePath: "",
            session: session,
            storageID: storageID,
            directories: &directories,
            files: &files,
            totalBytes: &totalBytes
        )

        directories.sort(by: Self.directorySort)
        files.sort(by: Self.fileSort)

        return TransferPlan(
            rootName: item.name,
            isDirectory: true,
            directories: directories,
            files: files,
            totalBytes: totalBytes
        )
    }

    private func scanDeviceFolder(
        handle: UInt32,
        relativePath: String,
        session: MTPDeviceSession,
        storageID: UInt32,
        directories: inout [String],
        files: inout [TransferFile],
        totalBytes: inout Int64?
    ) async throws {
        try Task.checkCancellation()

        let children = try await session.children(of: handle, storageID: storageID)
        for child in children {
            let name = child.info.filename
            let childPath = relativePath.isEmpty ? name : relativePath + "/" + name

            if child.info.isFolder {
                directories.append(childPath)
                try await scanDeviceFolder(
                    handle: child.handle,
                    relativePath: childPath,
                    session: session,
                    storageID: storageID,
                    directories: &directories,
                    files: &files,
                    totalBytes: &totalBytes
                )
                continue
            }

            let size = child.info.size.map { Int64(clamping: $0) }
            if let size {
                if let current = totalBytes {
                    totalBytes = current + size
                }
            } else {
                totalBytes = nil
            }

            files.append(
                TransferFile(
                    name: name,
                    relativeDirectory: relativePath,
                    size: size,
                    deviceHandle: child.handle,
                    localURL: nil
                )
            )
        }
    }

    private func executeDownload(
        plan: TransferPlan,
        session: MTPDeviceSession,
        downloads: URL,
        conflictResolution: ConflictResolution,
        onProgress: ((Double?) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let destinationURL = downloads.appendingPathComponent(plan.rootName)
        let destinationRoot: URL
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            switch conflictResolution {
            case .replace:
                try? FileManager.default.removeItem(at: destinationURL)
                destinationRoot = destinationURL
            case .keepBoth:
                destinationRoot = uniqueDestination(destinationURL, isDirectory: plan.isDirectory)
            case .cancel:
                throw CancellationError()
            }
        } else {
            destinationRoot = destinationURL
        }

        var finished = false
        defer {
            if !finished {
                try? FileManager.default.removeItem(at: destinationRoot)
            }
        }

        if plan.isDirectory {
            try FileManager.default.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true
            )
            for directory in plan.directories {
                try FileManager.default.createDirectory(
                    at: destinationRoot.appendingPathComponent(directory),
                    withIntermediateDirectories: true
                )
            }
        }

        transfer.start(title: l10n.t("transfer.downloading", plan.rootName), total: plan.totalBytes)

        var completed: Int64 = 0
        for file in plan.files {
            await transfer.waitIfPaused()
            try Task.checkCancellation()
            guard let handle = file.deviceHandle else { continue }

            let destination: URL
            let parent: URL
            if plan.isDirectory {
                parent = destinationRoot.appendingPathComponent(file.relativeDirectory)
                destination = parent.appendingPathComponent(file.name)
            } else {
                parent = destinationRoot.deletingLastPathComponent()
                destination = destinationRoot
            }

            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )

            var currentBytes: Int64 = 0
            try await session.download(handle: handle, to: destination) { written in
                currentBytes = written
                Task { @MainActor in
                    self.transfer.update(
                        completedBytes: completed,
                        currentBytes: written,
                        detail: file.name
                    )
                    if let total = plan.totalBytes, total > 0 {
                        onProgress?(min(1, Double(completed + written) / Double(total)))
                    } else {
                        onProgress?(nil)
                    }
                }
            }
            completed += currentBytes
        }

        finished = true
        transfer.finish(
            detail: l10n.t(
                "transfer.savedTo",
                FileManager.default.displayName(atPath: downloads.path)
            )
        )
    }

    // MARK: - Upload

    private func performUpload(items: [BrowserItem]) async {
        defer {
            transferTask = nil
            abortCurrentTransferOnCancel = false
        }

        guard let session = devices.session, let storage = device.storage else {
            alertMessage = l10n.t("alerts.noStorage")
            return
        }
        guard !items.isEmpty else {
            alertMessage = l10n.t("alerts.selectLocal")
            return
        }

        var usedNames = Set(device.items.map(\.name))
        var createdNames = Set<String>()

        let conflictNames = items.map(\.name).filter { usedNames.contains($0) }
        let conflictResolution: ConflictResolution
        if conflictNames.isEmpty {
            conflictResolution = .keepBoth
        } else {
            conflictResolution = await askConflictResolution(names: conflictNames)
            if conflictResolution == .cancel {
                transfer.canceled()
                return
            }
        }

        do {
            for item in items {
                await transfer.waitIfPaused()
                try Task.checkCancellation()
                transfer.start(title: l10n.t("transfer.preparing", item.name), total: nil)
                let plan = try makeUploadPlan(for: item)
                let rootName = try await executeUpload(
                    plan: plan,
                    session: session,
                    storageID: storage.id,
                    existingNames: usedNames,
                    conflictResolution: conflictResolution
                )
                usedNames.insert(rootName)
                createdNames.insert(rootName)
            }

            transfer.finish(detail: l10n.t("transfer.uploadedTo", storage.name))
            await device.reload()

            let currentNames = Set(device.items.map(\.name))
            if !createdNames.isSubset(of: currentNames) {
                // Some Android MTP servers return a stale handle list right
                // after SendObject; give them a moment and retry once.
                try? await Task.sleep(nanoseconds: 400_000_000)
                await device.reload()
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                transfer.canceled()
                await recoverAfterAbortedTransfer()
            } else {
                lastFailedUploadItems = items
                transfer.fail(error)
                alertMessage = error.localizedDescription
            }
        }
    }

    private func makeUploadPlan(for item: BrowserItem) throws -> TransferPlan {
        guard let url = item.url else {
            throw MTPError.invalidResponse("missing URL for \(item.name)")
        }

        if !item.isFolder {
            return TransferPlan(
                rootName: item.name,
                isDirectory: false,
                directories: [],
                files: [
                    TransferFile(
                        name: item.name,
                        relativeDirectory: "",
                        size: item.size,
                        deviceHandle: nil,
                        localURL: url
                    ),
                ],
                totalBytes: item.size
            )
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw MTPError.localFile("cannot enumerate \(url.path)")
        }

        let rootPath = url.standardizedFileURL.path
        var directories: [String] = []
        var files: [TransferFile] = []
        var totalBytes: Int64? = 0

        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                continue
            }

            let childPath = child.standardizedFileURL.path
            guard childPath.hasPrefix(rootPath + "/") else { continue }
            let relative = String(childPath.dropFirst(rootPath.count + 1))

            if values.isDirectory == true {
                directories.append(relative)
                continue
            }

            guard values.isRegularFile == true else { continue }
            let size = values.fileSize.map { Int64($0) }
            if let size {
                if let current = totalBytes {
                    totalBytes = current + size
                }
            } else {
                totalBytes = nil
            }

            files.append(
                TransferFile(
                    name: child.lastPathComponent,
                    relativeDirectory: (relative as NSString).deletingLastPathComponent,
                    size: size,
                    deviceHandle: nil,
                    localURL: child
                )
            )
        }

        directories.sort(by: Self.directorySort)
        files.sort(by: Self.fileSort)

        return TransferPlan(
            rootName: item.name,
            isDirectory: true,
            directories: directories,
            files: files,
            totalBytes: totalBytes
        )
    }

    private func executeUpload(
        plan: TransferPlan,
        session: MTPDeviceSession,
        storageID: UInt32,
        existingNames: Set<String>,
        conflictResolution: ConflictResolution,
        destinationParent: UInt32? = nil,
        existingItems: [BrowserItem]? = nil,
        onProgress: ((Double?) -> Void)? = nil
    ) async throws -> String {
        let hasConflict = existingNames.contains(plan.rootName)
        let rootName: String
        if hasConflict {
            switch conflictResolution {
            case .replace:
                for existing in (existingItems ?? device.items) where existing.name == plan.rootName {
                    guard let handle = existing.handle else { continue }
                    if existing.isFolder {
                        try await deleteDeviceFolder(
                            handle: handle,
                            storageID: storageID,
                            session: session
                        )
                    } else {
                        try await session.delete(handle: handle)
                    }
                }
                rootName = plan.rootName
            case .keepBoth:
                rootName = uniqueRemoteName(
                    plan.rootName,
                    existing: existingNames,
                    isDirectory: plan.isDirectory
                )
            case .cancel:
                throw CancellationError()
            }
        } else {
            rootName = plan.rootName
        }

        if !plan.isDirectory {
            guard let file = plan.files.first, let url = file.localURL else {
                throw MTPError.invalidResponse("empty upload plan for \(plan.rootName)")
            }
            try Task.checkCancellation()
            transfer.start(title: l10n.t("transfer.uploading", rootName), total: plan.totalBytes)

            var currentBytes: Int64 = 0
            _ = try await session.upload(
                fileURL: url,
                parent: destinationParent ?? device.currentParent,
                storageID: storageID,
                remoteName: rootName
            ) { written in
                currentBytes = written
                Task { @MainActor in
                    self.transfer.update(
                        completedBytes: 0,
                        currentBytes: written,
                        detail: rootName
                    )
                    if let total = plan.totalBytes, total > 0 {
                        onProgress?(min(1, Double(written) / Double(total)))
                    } else {
                        onProgress?(nil)
                    }
                }
            }
            _ = currentBytes
            transfer.finish(detail: l10n.t("transfer.uploaded", rootName))
            return rootName
        }

        let rootHandle = try await session.makeDirectory(
            name: rootName,
            parent: destinationParent ?? device.currentParent,
            storageID: storageID
        )

        var directoryHandles: [String: UInt32] = ["" : rootHandle]
        for directory in plan.directories {
            try Task.checkCancellation()
            let parentPath = (directory as NSString).deletingLastPathComponent
            let name = (directory as NSString).lastPathComponent
            let parentHandle = directoryHandles[parentPath] ?? rootHandle
            let handle = try await session.makeDirectory(
                name: name,
                parent: parentHandle,
                storageID: storageID
            )
            directoryHandles[directory] = handle
        }

        transfer.start(title: l10n.t("transfer.uploading", rootName), total: plan.totalBytes)

        var completed: Int64 = 0
        for file in plan.files {
            await transfer.waitIfPaused()
            try Task.checkCancellation()
            guard let url = file.localURL else { continue }
            let parentHandle = directoryHandles[file.relativeDirectory] ?? rootHandle

            var currentBytes: Int64 = 0
            _ = try await session.upload(
                fileURL: url,
                parent: parentHandle,
                storageID: storageID,
                remoteName: file.name
            ) { written in
                currentBytes = written
                Task { @MainActor in
                    self.transfer.update(
                        completedBytes: completed,
                        currentBytes: written,
                        detail: file.name
                    )
                    if let total = plan.totalBytes, total > 0 {
                        onProgress?(min(1, Double(completed + written) / Double(total)))
                    } else {
                        onProgress?(nil)
                    }
                }
            }
            completed += currentBytes
        }

        transfer.finish(detail: l10n.t("transfer.uploaded", rootName))
        return rootName
    }

    // MARK: - Naming helpers

    private func uniqueDestination(_ url: URL, isDirectory: Bool) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }

        if isDirectory {
            let name = url.lastPathComponent
            var index = 2
            while true {
                let candidate = url.deletingLastPathComponent()
                    .appendingPathComponent("\(name) \(index)")
                if !fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                index += 1
            }
        }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func uniqueRemoteName(
        _ name: String,
        existing: Set<String>,
        isDirectory: Bool
    ) -> String {
        guard existing.contains(name) else { return name }

        if isDirectory {
            var index = 2
            while true {
                let candidate = "\(name) \(index)"
                if !existing.contains(candidate) {
                    return candidate
                }
                index += 1
            }
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existing.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    private static func directorySort(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.split(separator: "/").count
        let rightDepth = rhs.split(separator: "/").count
        if leftDepth != rightDepth {
            return leftDepth < rightDepth
        }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func fileSort(_ lhs: TransferFile, _ rhs: TransferFile) -> Bool {
        if lhs.relativeDirectory != rhs.relativeDirectory {
            return lhs.relativeDirectory.localizedStandardCompare(rhs.relativeDirectory) == .orderedAscending
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Debug-only helpers

    #if DEBUG
    func debugDisconnectDevice() {
        Task {
            device.clear()
            await devices.disconnect()
        }
    }

    func debugUploadHomeFile(named name: String) {
        local.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        guard let file = local.items.first(where: { $0.name == name && !$0.isFolder }) else {
            alertMessage = l10n.t("alerts.debugFileNotFound", name)
            return
        }
        local.selection = [file.id]
        uploadSelected()
    }

    func debugUploadTestFolder() {
        let fileManager = FileManager.default
        let downloads = fileManager.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        let folder = downloads.appendingPathComponent("AndroidFileTransferKitUITest")

        try? fileManager.removeItem(at: folder)
        do {
            try fileManager.createDirectory(
                at: folder.appendingPathComponent("sub"),
                withIntermediateDirectories: true
            )
            try Data("hello from Android File Transfer UI\n".utf8)
                .write(to: folder.appendingPathComponent("one.txt"))
            try Data(repeating: 0x41, count: 256 * 1024)
                .write(to: folder.appendingPathComponent("sub/two.bin"))
        } catch {
            alertMessage = l10n.t("alerts.couldNotCreateTestFolder", error.localizedDescription)
            return
        }

        local.navigate(to: downloads)
        guard let item = local.items.first(where: { $0.name == "AndroidFileTransferKitUITest" }) else {
            alertMessage = l10n.t("alerts.testFolderNotVisible")
            return
        }
        local.selection = [item.id]
        uploadSelected()
    }

    func debugDownloadTestFolder() {
        Task {
            await device.reload()
            try? await Task.sleep(nanoseconds: 400_000_000)
            await device.reload()

            guard let folder = device.items.first(where: {
                $0.isFolder && $0.name.hasPrefix("AndroidFileTransferKitUITest")
            }) else {
                alertMessage = l10n.t("alerts.testFolderNotFound")
                return
            }
            device.selection = [folder.id]
            downloadSelected()
        }
    }

    func debugDeleteTestFoldersNow() {
        Task {
            await device.reload()
            try? await Task.sleep(nanoseconds: 400_000_000)
            await device.reload()

            guard let storage = device.storage else {
                alertMessage = l10n.t("alerts.noStorage")
                return
            }
            let items = device.items.filter { $0.name.hasPrefix("AndroidFileTransferKitUITest") }
            guard !items.isEmpty else {
                alertMessage = l10n.t("alerts.testFolderNotFound")
                return
            }
            device.selection = Set(items.map(\.id))
            pendingDelete = DeviceDeleteRequest(items: items, storageID: storage.id)
            confirmDeleteDeviceSelection()
        }
    }

    func debugResetUSBDevice() {
        devices.debugResetUSBDevice()
    }

    func debugTestDragProvider() {
        guard let file = device.items.first(where: { !$0.isFolder && $0.handle != nil }) else {
            alertMessage = l10n.t("alerts.noDeviceFile")
            return
        }
        debugExport(file, named: "AndroidFileTransferDragTest-\(file.name)")
    }

    private func debugExport(_ item: BrowserItem, named name: String) {
        guard let promise = filePromise(for: item) else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let destination = uniqueDestination(downloads.appendingPathComponent(name), isDirectory: item.isFolder)
        Task {
            do {
                try await promise.write(to: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func debugUploadLargeTestFile() {
        let fileManager = FileManager.default
        let downloads = fileManager.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        let url = downloads.appendingPathComponent("AndroidFileTransferKitLargeTest.bin")
        try? fileManager.removeItem(at: url)

        let totalBytes = 64 * 1024 * 1024
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0 ..< raw.count {
                base[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 5)
            }
        }

        guard fileManager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            alertMessage = l10n.t("alerts.testFolderNotVisible")
            return
        }
        var written = 0
        while written < totalBytes {
            let count = min(block.count, totalBytes - written)
            try? handle.write(contentsOf: Data(block.prefix(count)))
            written += count
        }
        try? handle.close()

        local.navigate(to: downloads)
        guard let item = local.items.first(where: { $0.name == "AndroidFileTransferKitLargeTest.bin" }) else {
            alertMessage = l10n.t("alerts.testFolderNotVisible")
            return
        }
        local.selection = [item.id]
        uploadSelected()
    }

    func debugCancelTransfer() {
        cancelTransfer()
    }

    func debugPauseTransfer() {
        pauseTransfer()
    }

    func debugResumeQueue() {
        queue.resume()
    }

    func debugTestFolderDragProvider() {
        guard let folder = device.items.first(where: { $0.isFolder && $0.name == "AndroidFileTransferKitUITest" }) else {
            alertMessage = l10n.t("alerts.testFolderNotFound")
            return
        }
        debugExport(folder, named: "AndroidFileTransferFolderDragTest")
    }

    func debugQuickLookFirstDeviceFile() {
        guard let file = device.items.first(where: { !$0.isFolder && $0.handle != nil }) else {
            alertMessage = l10n.t("alerts.noDeviceFile")
            return
        }
        device.selection = [file.id]
        quickLookSelection(preferDevice: true)
    }

    func debugQuickLookHomeFile(named name: String) {
        local.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        guard let file = local.items.first(where: { $0.name == name && !$0.isFolder }) else {
            alertMessage = l10n.t("alerts.debugFileNotFound", name)
            return
        }
        local.selection = [file.id]
        quickLookSelection()
    }

    func debugDownloadFirstDeviceFile() {
        guard let file = device.items.first(where: { !$0.isFolder && $0.handle != nil }) else {
            alertMessage = l10n.t("alerts.noDeviceFile")
            return
        }
        device.selection = [file.id]
        downloadSelected()
    }
    #endif
}

struct DeviceDeleteRequest: Identifiable {
    let id = UUID()
    let items: [BrowserItem]
    let storageID: UInt32
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    /// The first few conflicting names, for display.
    let names: [String]
    let totalCount: Int
}

enum ConflictResolution: Equatable {
    case replace
    case keepBoth
    case cancel
}

private struct TransferPlan {
    let rootName: String
    let isDirectory: Bool
    let directories: [String]
    let files: [TransferFile]
    let totalBytes: Int64?
}

private struct TransferFile {
    let name: String
    let relativeDirectory: String
    let size: Int64?
    let deviceHandle: UInt32?
    let localURL: URL?
}
