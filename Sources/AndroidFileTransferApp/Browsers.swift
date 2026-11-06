import AppKit
import Foundation
import AndroidFileTransferKit
import Observation

struct BrowserItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64?
    let date: Date?
    let handle: UInt32?
    let url: URL?
    let isSymbolicLink: Bool

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    var sizeText: String {
        guard let size else { return isFolder ? "—" : ">4 GB" }
        return Self.byteFormatter.string(fromByteCount: size)
    }

    var dateText: String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    var systemImage: String {
        if isSymbolicLink { return "link" }
        return isFolder ? "folder.fill" : "doc.fill"
    }

    static func from(url: URL) -> BrowserItem? {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
            return nil
        }

        // Resource values describe the symlink itself, not its target. Follow
        // the link so a symlinked directory is browsable like a folder.
        let isLink = values.isSymbolicLink ?? false
        let isFolder: Bool
        if isLink {
            var isDirectory: ObjCBool = false
            isFolder = FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        } else {
            isFolder = values.isDirectory ?? false
        }

        return BrowserItem(
            id: url.path,
            name: url.lastPathComponent,
            isFolder: isFolder,
            size: isFolder ? nil : values.fileSize.map { Int64($0) },
            date: values.contentModificationDate,
            handle: nil,
            url: url,
            isSymbolicLink: isLink
        )
    }
}

@MainActor
@Observable
final class LocalBrowser {
    var currentURL: URL
    var items: [BrowserItem] = []
    var selection: Set<String> = []
    var history: [URL] = []
    var isLoading = false
    var errorMessage: String?
    private(set) var accessDenied = false
    var showHiddenFiles: Bool = UserDefaults.standard.bool(forKey: "showHiddenFiles") {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: "showHiddenFiles")
            reload()
        }
    }

    init() {
        currentURL = FileManager.default.homeDirectoryForCurrentUser
        reload()
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = currentURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var canGoUp: Bool { currentURL.path != "/" }
    var canGoBack: Bool { !history.isEmpty }

    /// Directory reads must use the resolved target: `contentsOfDirectory`
    /// does not follow a symlink URL. `currentURL` keeps the user-visible path.
    private var listingURL: URL {
        currentURL.resolvingSymlinksInPath()
    }

    func navigate(to url: URL) {
        guard url != currentURL else {
            reload()
            return
        }
        history.append(currentURL)
        currentURL = url
        selection = []
        reload()
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        currentURL = previous
        selection = []
        reload()
    }

    func open(_ item: BrowserItem) {
        if item.isFolder {
            if let url = item.url {
                navigate(to: url)
            }
        } else if let url = item.url {
            NSWorkspace.shared.open(url)
        }
    }

    func selectedItems() -> [BrowserItem] {
        items.filter { selection.contains($0.id) }
    }

    func reload() {
        isLoading = true
        defer { isLoading = false }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: listingURL,
                includingPropertiesForKeys: nil,
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]
            )
            items = urls.compactMap(BrowserItem.from).sorted(by: Self.sort)

            errorMessage = nil
            accessDenied = false
        } catch {
            items = []
            errorMessage = error.localizedDescription
            let nsError = error as NSError
            accessDenied = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSFileReadNoPermissionError
        }
    }

    private static func sort(_ lhs: BrowserItem, _ rhs: BrowserItem) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

@MainActor
@Observable
final class DeviceBrowser {
    struct PathComponent: Identifiable, Hashable {
        let handle: UInt32
        let name: String
        var id: UInt32 { handle }
    }

    struct Location: Hashable {
        let parent: UInt32
        let path: [PathComponent]
    }

    private let manager: DeviceManager

    private(set) var storage: StorageItem?
    private(set) var currentParent: UInt32 = 0xFFFF_FFFF
    private(set) var path: [PathComponent] = []
    private(set) var history: [Location] = []

    var items: [BrowserItem] = []
    var selection: Set<String> = []
    var isLoading = false
    var errorMessage: String?
    private(set) var accessDenied = false
    private var isRecovering = false

    init(manager: DeviceManager) {
        self.manager = manager
    }

    var displayPath: String {
        let components = [storage?.name].compactMap { $0 } + path.map(\.name)
        return components.isEmpty ? "Phone" : components.joined(separator: " › ")
    }

    var canGoUp: Bool { !path.isEmpty }
    var canGoBack: Bool { !history.isEmpty }
    var isReady: Bool { storage != nil }

    func selectFirstStorageIfNeeded() async {
        guard storage == nil, let first = manager.storages.first else { return }
        await selectStorage(first)
    }

    func selectStorage(_ storage: StorageItem) async {
        self.storage = storage
        currentParent = 0xFFFF_FFFF
        path = []
        history = []
        selection = []
        await reload()
    }

    func clear() {
        storage = nil
        currentParent = 0xFFFF_FFFF
        path = []
        history = []
        selection = []
        items = []
        errorMessage = nil
    }

    func reload() async {
        await reload(allowRecovery: true)
    }

    private func reload(allowRecovery: Bool) async {
        guard let storage, let session = manager.session else {
            items = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let children = try await session.children(
                of: currentParent,
                storageID: storage.id
            )
            items = children.map { handle, info in
                BrowserItem(
                    id: "mtp-\(handle)",
                    name: info.filename,
                    isFolder: info.isFolder,
                    size: info.size.map { Int64(clamping: $0) },
                    date: info.modificationDate.date,
                    handle: handle,
                    url: nil,
                    isSymbolicLink: false
                )
            }
            .sorted(by: Self.sort)
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription

            guard allowRecovery,
                  !isRecovering,
                  Self.isIOError(error)
            else { return }

            isRecovering = true
            await manager.reconnect()
            isRecovering = false

            guard manager.isConnected else { return }

            if let refreshed = manager.storages.first(where: { $0.id == storage.id }) {
                self.storage = refreshed
            } else if let first = manager.storages.first {
                self.storage = first
                currentParent = 0xFFFF_FFFF
                path = []
                history = []
            } else {
                self.storage = nil
                return
            }
            await reload(allowRecovery: false)
        }
    }

    private static func isIOError(_ error: Error) -> Bool {
        if let mtp = error as? MTPError {
            switch mtp {
            case .transport(.deviceDisconnected),
                 .transport(.ioFailed),
                 .transport(.timeout),
                 .transport(.closed),
                 .transport(.pipeUnavailable):
                return true
            case let .invalidResponse(message):
                return isIOText(message)
            default:
                return false
            }
        }
        return isIOText(error.localizedDescription)
    }

    private static func isIOText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("enqueue io")
            || lower.contains("not attached")
            || lower.contains("no device")
            || lower.contains("disconnected")
            || lower.contains("usb i/o")
            || lower.contains("i/o failed")
    }

    func open(_ item: BrowserItem) async {
        guard item.isFolder, let handle = item.handle else { return }
        history.append(Location(parent: currentParent, path: path))
        path.append(PathComponent(handle: handle, name: item.name))
        currentParent = handle
        selection = []
        await reload()
    }

    func goUp() async {
        guard canGoUp else { return }
        history.append(Location(parent: currentParent, path: path))
        path.removeLast()
        currentParent = path.last?.handle ?? 0xFFFF_FFFF
        selection = []
        await reload()
    }

    func goBack() async {
        guard let previous = history.popLast() else { return }
        currentParent = previous.parent
        path = previous.path
        selection = []
        await reload()
    }

    func selectedItems() -> [BrowserItem] {
        items.filter { selection.contains($0.id) }
    }

    private static func sort(_ lhs: BrowserItem, _ rhs: BrowserItem) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
