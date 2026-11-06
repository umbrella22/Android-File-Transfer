import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showQueue = false

    var body: some View {
                @Bindable var model = appModel

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    LocalPaneView()
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    DevicePaneView()
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    TableDoubleClickMonitor { isLocal, row in
                        if isLocal {
                            guard appModel.local.items.indices.contains(row) else { return }
                            appModel.local.open(appModel.local.items[row])
                        } else {
                            guard appModel.device.items.indices.contains(row) else { return }
                            let item = appModel.device.items[row]
                            if item.isFolder {
                                Task { await appModel.device.open(item) }
                            } else {
                                appModel.device.selection = [item.id]
                                appModel.downloadSelected()
                            }
                        }
                    }
                )
                TransferBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQueue = true
                } label: {
                    Label(l10n.t("toolbar.transfers"), systemImage: "list.bullet")
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

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n

    var body: some View {
        List {
            Section(l10n.t("sidebar.favorites")) {
                ForEach(Favorites.all) { favorite in
                    Button {
                        appModel.local.navigate(to: favorite.url)
                    } label: {
                        Label(
                            l10n.t("favorites.\(favorite.id)"),
                            systemImage: favorite.systemImage
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Section(l10n.t("sidebar.devices")) {
                if let device = appModel.devices.deviceInfo {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(device.model, systemImage: "iphone")
                            .font(.headline)
                        Text("\(device.manufacturer) · MTP \(device.mtpVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    ForEach(appModel.devices.storages) { storage in
                        Button {
                            Task { await appModel.device.selectStorage(storage) }
                        } label: {
                            HStack(spacing: 6) {
                                Label(storage.name, systemImage: "internaldrive")
                                Spacer()
                                if appModel.device.storage?.id == storage.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.t("sidebar.noDevice"))
                            .foregroundStyle(.secondary)
                        if let error = appModel.devices.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Button(l10n.t("sidebar.refresh")) {
                            appModel.refreshDevice()
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

struct LocalPaneView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n
    @State private var selectionAnchor: String?

    var body: some View {
        @Bindable var local = appModel.local

        VStack(spacing: 0) {
            PaneHeader(
                title: local.displayPath,
                canGoBack: local.canGoBack,
                canGoUp: local.canGoUp,
                onBack: { local.goBack() },
                onUp: { local.goUp() },
                onRefresh: { local.reload() },
                actionTitle: l10n.t("header.upload"),
                actionImage: "arrow.up.circle",
                actionEnabled: appModel.canUpload,
                action: { appModel.uploadSelected() },
                shortcut: KeyboardShortcut("u", modifiers: .command),
                deleteEnabled: false,
                onDelete: nil,
                quickLookEnabled: !local.selectedItems().isEmpty,
                onQuickLook: { appModel.quickLookSelection() }
            )
            Divider()

            Table(local.items, selection: $local.selection) {
                TableColumn(l10n.t("column.name")) { item in
                    Label {
                        Text(item.name)
                    } icon: {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            selectLocalItem(item, flags: NSEvent.modifierFlags)
                        }
                    )
                    .onDrag {
                        if let url = item.url {
                            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                        }
                        return NSItemProvider()
                    }
                }
                .width(min: 120, ideal: 190)

                TableColumn(l10n.t("column.size")) { item in
                    Text(item.sizeText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 56, ideal: 75)

                TableColumn(l10n.t("column.dateModified")) { item in
                    Text(item.dateText)
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
            }
            .tableStyle(.inset)
            .overlay {
                if local.isLoading {
                    ProgressView()
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button(l10n.t("context.open")) {
                    if let item = local.items.first(where: { ids.contains($0.id) }) {
                        local.open(item)
                    }
                }
                Button(l10n.t("header.quickLook")) {
                    appModel.quickLookSelection()
                }
                Button(l10n.t("header.upload")) {
                    appModel.uploadSelected()
                }
                .disabled(!appModel.canUpload)
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
                freeSpace: nil
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: local.selection) { _, selection in
            if selection.count == 1, let id = selection.first {
                selectionAnchor = id
            }
        }
        .onChange(of: local.currentURL) { _, _ in
            selectionAnchor = nil
        }
    }

    private func selectLocalItem(
        _ item: BrowserItem,
        flags: NSEvent.ModifierFlags
    ) {
        let selection = appModel.local.selection

        if flags.contains(.command) {
            if selection.contains(item.id) {
                appModel.local.selection.remove(item.id)
            } else {
                appModel.local.selection.insert(item.id)
            }
            selectionAnchor = item.id
        } else if flags.contains(.shift),
                  let anchorID = selectionAnchor,
                  let anchor = appModel.local.items.firstIndex(where: { $0.id == anchorID }),
                  let target = appModel.local.items.firstIndex(where: { $0.id == item.id }) {
            let range = anchor <= target ? anchor...target : target...anchor
            appModel.local.selection = Set(appModel.local.items[range].map(\.id))
        } else {
            appModel.local.selection = [item.id]
            selectionAnchor = item.id
        }
    }
}

struct DevicePaneView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n
    @State private var isDropTargeted = false
    @State private var selectionAnchor: String?

    var body: some View {
        @Bindable var device = appModel.device

        VStack(spacing: 0) {
            PaneHeader(
                title: device.displayPath,
                canGoBack: device.canGoBack,
                canGoUp: device.canGoUp,
                onBack: { Task { await device.goBack() } },
                onUp: { Task { await device.goUp() } },
                onRefresh: { Task { await device.reload() } },
                actionTitle: l10n.t("header.download"),
                actionImage: "arrow.down.circle",
                actionEnabled: appModel.canDownload,
                action: { appModel.downloadSelected() },
                shortcut: KeyboardShortcut("d", modifiers: .command),
                deleteEnabled: appModel.canDeleteDevice,
                onDelete: { appModel.requestDeleteDeviceSelection() },
                quickLookEnabled: device.selectedItems().contains { !$0.isFolder },
                onQuickLook: { appModel.quickLookSelection() }
            )
            Divider()

            Group {
                if !appModel.devices.isConnected {
                ContentUnavailableView {
                    Label(l10n.t("empty.noDevice.title"), systemImage: "iphone.slash")
                } description: {
                    Text(l10n.t("empty.noDevice.description"))
                } actions: {
                    Button(l10n.t("empty.noDevice.refresh")) {
                        appModel.reconnectDevice()
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
                Table(device.items, selection: $device.selection) {
                    TableColumn(l10n.t("column.name")) { item in
                        Label {
                            Text(item.name)
                        } icon: {
                            Image(systemName: item.systemImage)
                                .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                selectDeviceItem(item, flags: NSEvent.modifierFlags)
                            }
                        )
                        .onDrag {
                            appModel.dragItemProvider(for: item) ?? NSItemProvider()
                        }
                    }
                    .width(min: 120, ideal: 190)

                    TableColumn(l10n.t("column.size")) { item in
                        Text(item.sizeText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 56, ideal: 75)

                    TableColumn(l10n.t("column.dateModified")) { item in
                        Text(item.dateText)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 150)
                }
                .tableStyle(.inset)
                .overlay {
                    if device.isLoading {
                        ProgressView()
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button(l10n.t("context.open")) {
                        if let item = device.items.first(where: { ids.contains($0.id) }) {
                            Task { await device.open(item) }
                        }
                    }
                    Button(l10n.t("header.quickLook")) {
                        appModel.quickLookSelection()
                    }
                    Button(l10n.t("header.download")) {
                        appModel.downloadSelected()
                    }
                    .disabled(!appModel.canDownload)
                    Button(l10n.t("header.delete"), role: .destructive) {
                        appModel.requestDeleteDeviceSelection()
                    }
                    .disabled(!appModel.canDeleteDevice)
                }
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
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: device.selection) { _, selection in
            if selection.count == 1, let id = selection.first {
                selectionAnchor = id
            }
        }
        .onChange(of: device.storage?.id) { _, _ in
            selectionAnchor = nil
        }
    }

    private func selectDeviceItem(
        _ item: BrowserItem,
        flags: NSEvent.ModifierFlags
    ) {
        let selection = appModel.device.selection

        if flags.contains(.command) {
            if selection.contains(item.id) {
                appModel.device.selection.remove(item.id)
            } else {
                appModel.device.selection.insert(item.id)
            }
            selectionAnchor = item.id
        } else if flags.contains(.shift),
                  let anchorID = selectionAnchor,
                  let anchor = appModel.device.items.firstIndex(where: { $0.id == anchorID }),
                  let target = appModel.device.items.firstIndex(where: { $0.id == item.id }) {
            let range = anchor <= target ? anchor...target : target...anchor
            appModel.device.selection = Set(appModel.device.items[range].map(\.id))
        } else {
            appModel.device.selection = [item.id]
            selectionAnchor = item.id
        }
    }
}

struct PaneHeader: View {
    @Environment(Localization.self) private var l10n

    let title: String
    let canGoBack: Bool
    let canGoUp: Bool
    let onBack: () -> Void
    let onUp: () -> Void
    let onRefresh: () -> Void
    let actionTitle: String
    let actionImage: String
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

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)

            Spacer()

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
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!actionEnabled)
            .keyboardShortcut(shortcut)
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
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

struct TransferBar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n

    var body: some View {
        let transfer = appModel.transfer

        if transfer.isActive || transfer.errorMessage != nil {
            HStack(spacing: 10) {
                if transfer.isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let fraction = transfer.fraction, transfer.isActive {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                } else if transfer.isActive {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(transfer.errorMessage ?? transfer.title)
                        .font(.callout)
                        .lineLimit(1)
                    if !transfer.detail.isEmpty {
                        Text(transfer.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if transfer.isActive, !transfer.isCompleted {
                    Button(transfer.isPaused ? l10n.t("transfer.resume") : l10n.t("transfer.pause")) {
                        if transfer.isPaused {
                            appModel.resumeTransfer()
                        } else {
                            appModel.pauseTransfer()
                        }
                    }
                    .controlSize(.small)

                    Button(l10n.t("transfer.cancel")) {
                        appModel.cancelTransfer()
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
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
}

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
                systemImage: "desktopcomputer",
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
