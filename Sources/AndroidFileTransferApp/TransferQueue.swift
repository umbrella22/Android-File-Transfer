import Foundation
import Observation

struct TransferJob: Codable, Identifiable, Equatable {
    enum Direction: String, Codable {
        case download
        case upload
    }

    enum State: String, Codable {
        case pending
        case running
        case paused
        case completed
        case failed
        case canceled
    }

    let id: UUID
    var direction: Direction
    var displayName: String
    var createdAt: Date
    var state: State
    var errorMessage: String?
    var progress: Double?

    var storageID: UInt32?
    var storageName: String?
    var folderPath: [String]
    var itemName: String?
    var localURLPaths: [String]?
    /// Folder a download is saved into. Jobs persisted before this existed
    /// decode it as nil and keep saving to Downloads.
    var localDestinationPath: String?

    init(
        id: UUID = UUID(),
        direction: Direction,
        displayName: String,
        createdAt: Date = Date(),
        state: State = .pending,
        errorMessage: String? = nil,
        progress: Double? = nil,
        storageID: UInt32?,
        storageName: String?,
        folderPath: [String],
        itemName: String?,
        localURLPaths: [String]?,
        localDestinationPath: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.displayName = displayName
        self.createdAt = createdAt
        self.state = state
        self.errorMessage = errorMessage
        self.progress = progress
        self.storageID = storageID
        self.storageName = storageName
        self.folderPath = folderPath
        self.itemName = itemName
        self.localURLPaths = localURLPaths
        self.localDestinationPath = localDestinationPath
    }
}

struct TransferQueueStore {
    let url: URL

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("com.androidfiletransfer.remake", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        url = base.appendingPathComponent("transfer-queue.json")
    }

    init(url: URL) { self.url = url }

    func load() -> [TransferJob] {
        guard let data = try? Data(contentsOf: url),
              var jobs = try? JSONDecoder().decode([TransferJob].self, from: data)
        else {
            return []
        }

        // A job that was running when the app exited is no longer running.
        for index in jobs.indices where jobs[index].state == .running {
            jobs[index].state = .paused
            jobs[index].errorMessage = "Interrupted"
        }
        return jobs
    }

    func save(_ jobs: [TransferJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
@Observable
final class TransferQueue {
    private(set) var jobs: [TransferJob]
    private(set) var isPaused = false
    private(set) var isProcessing = false
    private(set) var currentJobID: UUID?

    var runner: ((TransferJob) async throws -> Void)?
    var onAbortRequested: (() -> Void)?

    private let store: TransferQueueStore
    private var worker: Task<Void, Never>?
    private var currentRun: Task<Void, Error>?
    private enum StopRequest { case pause, cancel }
    private var stopRequest: StopRequest?
    private var deviceActionInProgress = false
    private var startAfterDeviceAction = false

    init(store: TransferQueueStore = TransferQueueStore()) {
        self.store = store
        jobs = store.load()
    }

    var isAborting: Bool { stopRequest != nil }
    var hasPendingJobs: Bool { jobs.contains { $0.state == .pending } }
    var hasPausedJobs: Bool { jobs.contains { $0.state == .paused } }
    var hasActiveJobs: Bool { currentJobID != nil || hasPendingJobs || hasPausedJobs }
    var canControlCurrent: Bool { currentJobID != nil && !isAborting }
    var canResume: Bool { worker == nil && (hasPendingJobs || hasPausedJobs) }
    var canBeginDeviceAction: Bool { !deviceActionInProgress && worker == nil }

    // Preview and deletion share the transfer indicator with the worker. Reserve
    // it before spawning either task, while still allowing jobs to be enqueued.
    func beginDeviceAction() -> Bool {
        guard canBeginDeviceAction else { return false }
        deviceActionInProgress = true
        return true
    }

    func endDeviceAction() {
        deviceActionInProgress = false
        if startAfterDeviceAction {
            startAfterDeviceAction = false
            start()
        }
    }

    func enqueue(_ newJobs: [TransferJob]) {
        guard !newJobs.isEmpty else { return }
        jobs.append(contentsOf: newJobs)
        persist()
        start()
    }

    func start() {
        guard worker == nil, !isPaused, hasPendingJobs else { return }
        guard !deviceActionInProgress else {
            startAfterDeviceAction = true
            return
        }
        worker = Task { await processLoop() }
    }

    func pause() {
        guard currentJobID != nil else {
            isPaused = true
            return
        }
        stopCurrent(.pause)
    }

    func resume() {
        guard worker == nil else { return }
        isPaused = false

        var changed = false
        for index in jobs.indices where jobs[index].state == .paused {
            jobs[index].state = .pending
            jobs[index].errorMessage = nil
            changed = true
        }
        if changed {
            persist()
        }
        start()
    }

    func cancelCurrent() {
        stopCurrent(.cancel)
    }

    private func stopCurrent(_ request: StopRequest) {
        guard let currentRun, stopRequest == nil else { return }
        stopRequest = request
        currentRun.cancel()
        onAbortRequested?()
    }

    func cancelAll() {
        stopCurrent(.cancel)
        for index in jobs.indices where jobs[index].state == .pending || jobs[index].state == .paused {
            jobs[index].state = .canceled
        }
        persist()
    }

    func retry(_ id: UUID) {
        guard !isAborting, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .failed, .canceled, .paused:
            jobs[index].state = .pending
            jobs[index].errorMessage = nil
            jobs[index].progress = nil
            isPaused = false
            persist()
            start()
        default:
            break
        }
    }

    func retryLastFailed() {
        if let index = jobs.firstIndex(where: {
            $0.state == .failed || $0.state == .canceled || $0.state == .paused
        }) {
            retry(jobs[index].id)
        }
    }

    func remove(_ id: UUID) {
        guard currentJobID != id else { return }
        jobs.removeAll { $0.id == id }
        persist()
    }

    func clearCompleted() {
        jobs.removeAll {
            $0.state == .completed || $0.state == .canceled
        }
        persist()
    }

    func setProgress(_ id: UUID, progress: Double?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = progress
    }

    private func processLoop() async {
        isProcessing = true
        defer {
            isProcessing = false
            currentJobID = nil
            worker = nil
            persist()

            if !isPaused, hasPendingJobs {
                start()
            }
        }

        while !isPaused {
            guard let index = jobs.firstIndex(where: { $0.state == .pending }) else {
                break
            }

            let job = jobs[index]
            currentJobID = job.id
            jobs[index].state = .running
            jobs[index].errorMessage = nil
            persist()

            let run = Task { [runner] in
                try Task.checkCancellation()
                try await runner?(job)
                return ()
            }
            currentRun = run
            do {
                try await run.value
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].state = .completed
                    jobs[idx].progress = 1
                    jobs[idx].errorMessage = nil
                }
            } catch {
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    if stopRequest == .pause {
                        jobs[idx].state = .paused
                        jobs[idx].errorMessage = nil
                    } else if stopRequest == .cancel || error is CancellationError {
                        jobs[idx].state = .canceled
                        jobs[idx].errorMessage = nil
                    } else {
                        jobs[idx].state = .failed
                        jobs[idx].errorMessage = error.localizedDescription
                    }
                }
            }

            currentRun = nil
            currentJobID = nil
            if let request = stopRequest {
                stopRequest = nil
                isPaused = request == .pause || hasPendingJobs
            }
            persist()
        }
    }

    private func persist() {
        store.save(jobs)
    }
}
