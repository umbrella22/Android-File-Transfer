import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showQueue = false

    var body: some View {
        @Bindable var model = appModel

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    LocalPaneView()
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    DevicePaneView()
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TransferBar { showQueue = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQueue = true
                } label: {
                    Label(
                        l10n.t("toolbar.transfers"),
                        systemImage: appModel.queue.hasActiveJobs
                            ? "arrow.up.arrow.down.circle.fill"
                            : "arrow.up.arrow.down.circle"
                    )
                }
                .help(l10n.t("toolbar.transfers"))
                .keyboardShortcut("j", modifiers: .command)
            }
        }
        .sheet(isPresented: $showQueue) {
            TransferQueueView()
        }
        .sheet(item: $model.conflictRequest) { request in
            ConflictSheet(request: request) { resolution in
                model.resolveConflict(resolution)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { !hasOnboarded },
                set: { if !$0 { hasOnboarded = true } }
            )
        ) {
            OnboardingView {
                hasOnboarded = true
            }
        }
        .alert(
            "Android File Transfer",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button(l10n.t("general.ok"), role: .cancel) {
                model.alertMessage = nil
            }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task(id: model.devices.storages.map(\.id)) {
            await model.device.selectFirstStorageIfNeeded()
        }
        .onChange(of: model.devices.isConnected) { _, connected in
            if !connected {
                model.device.clear()
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n

    var body: some View {
        List {
            Section(l10n.t("sidebar.favorites")) {
                ForEach(Favorites.all) { favorite in
                    let isCurrent = appModel.local.currentURL.standardizedFileURL
                        == favorite.url.standardizedFileURL
                    Button {
                        appModel.local.navigate(to: favorite.url)
                    } label: {
                        Label(
                            l10n.t("favorites.\(favorite.id)"),
                            systemImage: favorite.systemImage
                        )
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section(l10n.t("sidebar.devices")) {
                if let device = appModel.devices.deviceInfo {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(device.model, systemImage: "smartphone")
                            .font(.headline)
                        Text("\(device.manufacturer) · MTP \(device.mtpVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    ForEach(appModel.devices.storages) { storage in
                        StorageRow(
                            storage: storage,
                            isSelected: appModel.device.storage?.id == storage.id
                        ) {
                            Task { await appModel.device.selectStorage(storage) }
                        }
                    }
                } else if appModel.devices.isConnecting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(l10n.t("sidebar.connecting"))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.t("sidebar.noDevice"))
                            .foregroundStyle(.secondary)
                        if let error = appModel.devices.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Button {
                            appModel.refreshDevice()
                        } label: {
                            Label(l10n.t("sidebar.refresh"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Android File Transfer")
    }
}

private struct StorageRow: View {
    @Environment(Localization.self) private var l10n

    let storage: StorageItem
    let isSelected: Bool
    let action: () -> Void

    private var usedFraction: Double {
        guard storage.maxCapacity > 0 else { return 0 }
        let used = storage.maxCapacity - min(storage.freeSpace, storage.maxCapacity)
        return Double(used) / Double(storage.maxCapacity)
    }

    private var capacityText: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: storage.maxCapacity),
            countStyle: .file
        )
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(storage.name, systemImage: "internaldrive")
                        .fontWeight(isSelected ? .semibold : .regular)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }

                if storage.maxCapacity > 0 {
                    ProgressView(value: usedFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(usedFraction > 0.9 ? .orange : .accentColor)
                    Text(l10n.t("sidebar.capacity", storage.freeSpaceText, capacityText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panes

struct LocalPaneView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var local = appModel.local

        VStack(spacing: 0) {
            PaneHeader(
                paneImage: "laptopcomputer",
                title: local.folderName,
                fullPath: local.displayPath,
                pathMenu: local.ancestors.enumerated().map { index, url in
                    PathEntry(
                        id: index,
                        name: FileManager.default.displayName(atPath: url.path),
                        systemImage: url.path == "/" ? "internaldrive" : "folder"
                    ) {
                        local.navigate(to: url)
                    }
                },
                canGoBack: local.canGoBack,
                canGoUp: local.canGoUp,
                onBack: { local.goBack() },
                onUp: { local.goUp() },
                onRefresh: { local.reload() },
                actionTitle: l10n.t("header.uploadToPhone"),
                actionImage: "arrow.right.circle",
                actionHelp: l10n.t(
                    "header.uploadHelp",
                    appModel.device.folderName ?? l10n.t("pane.phone")
                ),
                actionEnabled: appModel.canUpload,
                action: { appModel.uploadSelected() },
                shortcut: KeyboardShortcut("u", modifiers: .command),
                deleteEnabled: false,
                onDelete: nil,
                quickLookEnabled: !local.selection.isEmpty,
                onQuickLook: { appModel.quickLookSelection() }
            )
            Divider()

            Table(
                of: BrowserItem.self,
                selection: $local.selection,
                sortOrder: $local.sortOrder
            ) {
                BrowserTable.columns(l10n)
            } rows: {
                ForEach(local.items) { item in
                    TableRow(item)
                        .itemProvider {
                            item.url.flatMap { NSItemProvider(contentsOf: $0) }
                        }
                }
            }
            .tableStyle(.inset)
            .overlay {
                if local.items.isEmpty, local.errorMessage == nil, !local.isLoading {
                    Text(l10n.t("empty.folder"))
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                open(ids)
            }
            .onKeyPress(.space) {
                guard !local.selection.isEmpty else { return .ignored }
                appModel.quickLookSelection()
                return .handled
            }

            if let error = local.errorMessage {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)

                    Text(local.accessDenied
                        ? l10n.t("local.accessDenied")
                        : error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)

                    Spacer()

                    if local.accessDenied {
                        Button(l10n.t("local.openPrivacySettings")) {
                            AccessGuideWindowController.shared.show(
                                l10n: l10n,
                                onRecheck: { local.reload() }
                            )
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()
            PaneStatusBar(
                count: local.items.count,
                selection: local.selection.count,
                freeSpace: local.freeSpaceText
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if let drag = appModel.deviceDrag {
                DeviceDownloadDropTarget(sequence: drag.sequence, accept: appModel.acceptDeviceDrop, isTargeted: $isDropTargeted)
            }
        }
        .overlay {
            if isDropTargeted, appModel.deviceDrag != nil {
                DropHighlight(
                    text: l10n.t("drop.download", local.folderName),
                    systemImage: "arrow.left.circle"
                )
            }
        }
    }

    private func items(_ ids: Set<String>) -> [BrowserItem] {
        appModel.local.items.filter { ids.contains($0.id) }
    }

    private func open(_ ids: Set<String>) {
        let items = items(ids)
        if items.count == 1 {
            appModel.local.open(items[0])
        } else {
            items.filter { !$0.isFolder }.forEach(appModel.local.open)
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        if ids.isEmpty {
            Button(l10n.t("header.refresh")) {
                appModel.local.reload()
            }
        } else {
            Button(l10n.t("context.open")) {
                open(ids)
            }
            Button(l10n.t("header.quickLook")) {
                appModel.local.selection = ids
                appModel.quickLookSelection()
            }
            Button(l10n.t("context.showInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting(items(ids).compactMap(\.url))
            }
            Divider()
            Button(l10n.t("header.uploadToPhone")) {
                appModel.local.selection = ids
                appModel.uploadSelected()
            }
            .disabled(!appModel.devices.isConnected || appModel.device.storage == nil)
        }
    }
}

struct DevicePaneView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n
    @State private var isDropTargeted = false

    private var title: String {
        appModel.device.folderName
            ?? appModel.devices.deviceInfo?.model
            ?? l10n.t("pane.phone")
    }

    /// Storage root and folders, innermost first.
    private var pathMenu: [PathEntry] {
        let device = appModel.device
        guard let storage = device.storage else { return [] }
        let levels = [(storage.name, "internaldrive")]
            + device.path.map { ($0.name, "folder") }
        return levels.enumerated().reversed().enumerated().map { index, level in
            let (depth, (name, image)) = level
            return PathEntry(id: index, name: name, systemImage: image) {
                Task { await device.navigate(toDepth: depth) }
            }
        }
    }

    var body: some View {
        @Bindable var device = appModel.device

        VStack(spacing: 0) {
            PaneHeader(
                paneImage: "smartphone",
                title: title,
                fullPath: device.displayPath,
                pathMenu: pathMenu,
                canGoBack: device.canGoBack,
                canGoUp: device.canGoUp,
                onBack: { Task { await device.goBack() } },
                onUp: { Task { await device.goUp() } },
                onRefresh: { Task { await device.reload() } },
                actionTitle: l10n.t("header.downloadToMac"),
                actionImage: "arrow.left.circle",
                actionHelp: l10n.t(
                    "header.downloadHelp",
                    FileManager.default.displayName(atPath: appModel.downloadDestination.path)
                ),
                actionEnabled: appModel.canDownload,
                action: { appModel.downloadSelected() },
                shortcut: KeyboardShortcut("d", modifiers: .command),
                deleteEnabled: appModel.canDeleteDevice,
                onDelete: { appModel.requestDeleteDeviceSelection() },
                quickLookEnabled: appModel.canPreviewDeviceSelection,
                onQuickLook: { appModel.quickLookSelection(preferDevice: true) }
            )
            Divider()

            Group {
                if !appModel.devices.isConnected {
                    if appModel.devices.isConnecting {
                        ProgressView {
                            Text(l10n.t("sidebar.connecting"))
                        }
                    } else {
                        ContentUnavailableView {
                            Label(l10n.t("empty.noDevice.title"), systemImage: "iphone.slash")
                        } description: {
                            Text(l10n.t("empty.noDevice.description"))
                        } actions: {
                            Button(l10n.t("empty.noDevice.refresh")) {
                                appModel.reconnectDevice()
                            }
                        }
                    }
                } else if let error = device.errorMessage {
                    ContentUnavailableView {
                        Label(l10n.t("empty.error.title"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(l10n.t("empty.error.retry")) {
                            appModel.reconnectDevice()
                        }
                    }
                } else if !device.isReady {
                    ContentUnavailableView {
                        Label(l10n.t("empty.selectStorage.title"), systemImage: "internaldrive")
                    } description: {
                        Text(l10n.t("empty.selectStorage.description"))
                    }
                } else {
                    deviceTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if device.isReady {
                Divider()
                PaneStatusBar(
                    count: device.items.count,
                    selection: device.selection.count,
                    freeSpace: device.storage?.freeSpaceText
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(
            l10n.t("delete.title"),
            isPresented: Binding(
                get: { appModel.pendingDelete != nil },
                set: { if !$0 { appModel.cancelDeleteDeviceSelection() } }
            )
        ) {
            Button(l10n.t("delete.confirm"), role: .destructive) {
                appModel.confirmDeleteDeviceSelection()
            }
            Button(l10n.t("delete.cancel"), role: .cancel) {
                appModel.cancelDeleteDeviceSelection()
            }
        } message: {
            if let request = appModel.pendingDelete {
                Text(l10n.t("delete.message", request.items.count))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            appModel.uploadDroppedURLs(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted, device.isReady {
                DropHighlight(
                    text: l10n.t("drop.upload", title),
                    systemImage: "arrow.right.circle"
                )
            }
        }
    }

    private var deviceTable: some View {
        @Bindable var device = appModel.device

        return DeviceFileTable(
            model: appModel, items: device.items, selection: $device.selection,
            titles: [l10n.t("column.name"), l10n.t("column.size"), l10n.t("column.dateModified")],
            open: open, menu: { NSHostingMenu(rootView: menu(for: $0)) }
        )
        .overlay {
            if device.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if device.items.isEmpty {
                Text(l10n.t("empty.folder"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Double-click or Return: open a single folder, download files.
    private func open(_ ids: Set<String>) {
        let device = appModel.device
        let items = device.items.filter { ids.contains($0.id) }
        if items.count == 1, let folder = items.first, folder.isFolder {
            Task { await device.open(folder) }
        } else if !items.isEmpty {
            device.selection = ids
            appModel.downloadSelected()
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        let device = appModel.device
        if ids.isEmpty {
            Button(l10n.t("header.refresh")) {
                Task { await device.reload() }
            }
        } else {
            Button(l10n.t("context.open")) {
                open(ids)
            }
            Button(l10n.t("header.quickLook")) {
                device.selection = ids
                appModel.quickLookSelection(preferDevice: true)
            }
            .disabled(!appModel.queue.canBeginDeviceAction || device.previewItem(in: ids) == nil)
            Divider()
            Button(l10n.t("header.downloadToMac")) {
                device.selection = ids
                appModel.downloadSelected()
            }
            Divider()
            Button(l10n.t("header.delete"), role: .destructive) {
                device.selection = ids
                appModel.requestDeleteDeviceSelection()
            }
            .disabled(!appModel.queue.canBeginDeviceAction)
        }
    }
}

enum BrowserTable {
    @MainActor
    @TableColumnBuilder<BrowserItem, KeyPathComparator<BrowserItem>>
    static func columns(
        _ l10n: Localization
    ) -> some TableColumnContent<BrowserItem, KeyPathComparator<BrowserItem>> {
        TableColumn(l10n.t("column.name"), value: \.name, comparator: .localizedStandard) { item in
            Label {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: item.systemImage)
                    .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
            }
            .help(item.name)
        }
        .width(min: 140, ideal: 220)

        TableColumn(l10n.t("column.size"), value: \.sortSize) { item in
            Text(item.sizeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 80)

        TableColumn(l10n.t("column.dateModified"), value: \.sortDate) { item in
            Text(item.dateText)
                .foregroundStyle(.secondary)
        }
        .width(min: 120, ideal: 160)
    }
}

// MARK: - Pane chrome

struct PathEntry: Identifiable {
    let id: Int
    let name: String
    let systemImage: String
    let action: () -> Void
}

struct PaneHeader: View {
    @Environment(Localization.self) private var l10n

    let paneImage: String
    let title: String
    let fullPath: String
    let pathMenu: [PathEntry]
    let canGoBack: Bool
    let canGoUp: Bool
    let onBack: () -> Void
    let onUp: () -> Void
    let onRefresh: () -> Void
    let actionTitle: String
    let actionImage: String
    let actionHelp: String
    let actionEnabled: Bool
    let action: () -> Void
    let shortcut: KeyboardShortcut?
    let deleteEnabled: Bool
    let onDelete: (() -> Void)?
    let quickLookEnabled: Bool
    let onQuickLook: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!canGoBack)
            .help(l10n.t("header.back"))

            Button(action: onUp) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canGoUp)
            .help(l10n.t("header.up"))

            Image(systemName: paneImage)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Group {
                if pathMenu.count > 1 {
                    Menu {
                        ForEach(pathMenu) { entry in
                            Button(action: entry.action) {
                                Label(entry.name, systemImage: entry.systemImage)
                            }
                        }
                    } label: {
                        Text(title)
                            .font(.headline)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                } else {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(fullPath.isEmpty ? title : fullPath)
            .layoutPriority(-1)

            Spacer(minLength: 8)

            Button(action: onQuickLook) {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .disabled(!quickLookEnabled)
            .help(l10n.t("header.quickLook"))

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(l10n.t("header.refresh"))

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!deleteEnabled)
                .help(l10n.t("header.delete"))
                .keyboardShortcut(.delete, modifiers: .command)
            }

            Button(action: action) {
                Label(actionTitle, systemImage: actionImage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!actionEnabled)
            .keyboardShortcut(shortcut)
            .help(actionHelp)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }
}

struct PaneStatusBar: View {
    @Environment(Localization.self) private var l10n

    let count: Int
    let selection: Int
    let freeSpace: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(l10n.t("status.items", count))
            if selection > 0 {
                Text(l10n.t("status.selected", selection))
            }
            Spacer()
            if let freeSpace {
                Text(l10n.t("status.free", freeSpace))
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

struct DropHighlight: View {
    let text: String
    let systemImage: String

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 2)
            Label(text, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 36)
        }
        .padding(4)
        .allowsHitTesting(false)
    }
}

// MARK: - Transfer bar

struct TransferBar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n

    let onShowQueue: () -> Void

    var body: some View {
        let transfer = appModel.transfer
        let queue = appModel.queue
        let queued = queue.jobs.filter { $0.state == .pending }.count
        let paused = queue.hasPausedJobs || (queue.isPaused && queued > 0)

        if transfer.isActive || transfer.errorMessage != nil || queued > 0 || paused || queue.isAborting {
            HStack(spacing: 10) {
                if transfer.isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let fraction = transfer.fraction, transfer.isActive {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 160)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                } else if transfer.isActive {
                    ProgressView()
                        .controlSize(.small)
                } else if transfer.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        transfer.errorMessage
                            ?? (transfer.isActive
                                ? transfer.title
                                : idleTitle(paused: paused, stopping: queue.isAborting, waiting: queued))
                    )
                    .font(.callout)
                    .lineLimit(1)

                    let details = [
                        transfer.isActive ? transfer.detail : "",
                        transfer.isActive && queued > 0 ? l10n.t("transfer.queued", queued) : "",
                    ].filter { !$0.isEmpty }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if queue.canControlCurrent, !transfer.isCompleted {
                    Button(l10n.t("transfer.pause")) {
                        appModel.pauseTransfer()
                    }
                    .controlSize(.small)

                    Button(l10n.t("transfer.cancel")) {
                        appModel.cancelTransfer()
                    }
                    .controlSize(.small)
                } else if queue.canResume, appModel.devices.isConnected {
                    Button(l10n.t("queue.resume")) {
                        appModel.resumeTransfer()
                    }
                    .controlSize(.small)
                }

                if !transfer.isActive, transfer.errorMessage != nil {
                    if appModel.canRetryLastTransfer {
                        Button(l10n.t("transfer.retry")) {
                            appModel.retryLastTransfer()
                        }
                        .controlSize(.small)
                    }
                    Button(l10n.t("transfer.dismiss")) {
                        appModel.dismissTransferError()
                    }
                    .controlSize(.small)
                }

                Button(action: onShowQueue) {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.borderless)
                .help(l10n.t("transfer.showQueue"))
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }

    private func idleTitle(paused: Bool, stopping: Bool, waiting: Int) -> String {
        if stopping { return l10n.t("transfer.canceling") }
        if paused { return l10n.t("transfer.paused") }
        return l10n.t("transfer.waiting", waiting)
    }
}

// MARK: - Favorites

struct Favorite: Identifiable {
    let id: String
    let systemImage: String
    let url: URL
}

enum Favorites {
    static let all: [Favorite] = {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        func directory(
            _ searchPath: FileManager.SearchPathDirectory,
            fallback: String
        ) -> URL {
            fileManager.urls(for: searchPath, in: .userDomainMask).first
                ?? home.appendingPathComponent(fallback)
        }

        return [
            Favorite(id: "home", systemImage: "house", url: home),
            Favorite(
                id: "desktop",
                systemImage: "menubar.dock.rectangle",
                url: directory(.desktopDirectory, fallback: "Desktop")
            ),
            Favorite(
                id: "downloads",
                systemImage: "arrow.down.circle",
                url: directory(.downloadsDirectory, fallback: "Downloads")
            ),
            Favorite(
                id: "documents",
                systemImage: "doc",
                url: directory(.documentDirectory, fallback: "Documents")
            ),
        ]
    }()
}
