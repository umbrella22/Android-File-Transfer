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
        localURLPaths: [String]?
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

    private let store = TransferQueueStore()
    private var worker: Task<Void, Never>?
    private var pauseRequested = false
    private var cancelRequested = false

    init() {
        jobs = store.load()
    }

    var isAborting: Bool { pauseRequested || cancelRequested }

    var hasPendingJobs: Bool {
        jobs.contains { $0.state == .pending }
    }

    var hasActiveJobs: Bool {
        currentJobID != nil || hasPendingJobs
    }

    func enqueue(_ newJobs: [TransferJob]) {
        guard !newJobs.isEmpty else { return }
        jobs.append(contentsOf: newJobs)
        persist()
        start()
    }

    func start() {
        guard worker == nil, !isPaused else { return }
        worker = Task { await processLoop() }
    }

    func pause() {
        guard currentJobID != nil else {
            isPaused = true
            return
        }
        pauseRequested = true
        onAbortRequested?()
    }

    func resume() {
        isPaused = false
        pauseRequested = false
        cancelRequested = false

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
        guard currentJobID != nil else { return }
        cancelRequested = true
        onAbortRequested?()
    }

    func cancelAll() {
        cancelRequested = true
        onAbortRequested?()
        for index in jobs.indices where jobs[index].state == .pending || jobs[index].state == .paused {
            jobs[index].state = .canceled
        }
        persist()
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .failed, .canceled, .paused:
            jobs[index].state = .pending
            jobs[index].errorMessage = nil
            jobs[index].progress = nil
            isPaused = false
            pauseRequested = false
            if !isProcessing {
                cancelRequested = false
            }
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

            if !isPaused, !cancelRequested, hasPendingJobs {
                start()
            }
        }

        while !isPaused, !cancelRequested {
            guard let index = jobs.firstIndex(where: { $0.state == .pending }) else {
                break
            }

            let job = jobs[index]
            currentJobID = job.id
            jobs[index].state = .running
            jobs[index].errorMessage = nil
            persist()

            do {
                try await runner?(job)
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].state = .completed
                    jobs[idx].progress = 1
                    jobs[idx].errorMessage = nil
                }
            } catch {
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    if pauseRequested {
                        jobs[idx].state = .paused
                        jobs[idx].errorMessage = nil
                    } else if cancelRequested || Task.isCancelled || error is CancellationError {
                        jobs[idx].state = .canceled
                        jobs[idx].errorMessage = nil
                    } else {
                        jobs[idx].state = .failed
                        jobs[idx].errorMessage = error.localizedDescription
                    }
                }
            }

            currentJobID = nil
            persist()

            if pauseRequested || cancelRequested {
                if pauseRequested {
                    isPaused = true
                }
                break
            }
        }
    }

    private func persist() {
        store.save(jobs)
    }
}
