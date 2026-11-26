import Foundation

@MainActor
final class DevicePreviewCache {
    private let root: URL

    init(directory: URL = FileManager.default.temporaryDirectory) {
        root = directory.appendingPathComponent("AndroidFileTransfer-QuickLook-\(UUID())", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(for item: BrowserItem, handle: UInt32, sessionID: UUID,
              download: (URL) async throws -> Void) async throws -> URL {
        let version = [String(handle), item.size.map(String.init) ?? "-",
                       item.date.map { String($0.timeIntervalSince1970) } ?? "-"].joined(separator: "-")
        let folder = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let destination = folder.appendingPathComponent(item.name)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return destination }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: staging) }
        try await download(staging)
        try Task.checkCancellation()
        // Publish only closed, complete files. A concurrent request may have finished first.
        if !fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: staging, to: destination)
        }
        return destination
    }
}
