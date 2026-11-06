import AppKit
import SwiftUI

struct AccessGuideView: View {
    @Environment(Localization.self) private var l10n

    let onClose: () -> Void
    let onRecheck: (() -> Void)?

    @State private var fullDiskAccessGranted = false

    private var applicationURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
        }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.androidfiletransfer.remake"
        ) ?? Bundle.main.bundleURL
    }

    private var applicationIcon: NSImage {
        NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private var applicationProvider: NSItemProvider {
        NSItemProvider(contentsOf: applicationURL) ?? NSItemProvider()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                filesCard
                fdaCard
                footer
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 600, height: 540)
        .onAppear {
            refreshStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: applicationIcon)
                .resizable()
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("access.title"))
                    .font(.title2.weight(.semibold))
                Text(l10n.t("access.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var filesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(l10n.t("access.files.title"), systemImage: "folder")
                    .font(.headline)

                Text(l10n.t("access.files.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(l10n.t("access.files.open")) {
                    openPrivacySettings("Privacy_FilesAndFolders")
                }

                Text(l10n.t("access.files.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fdaCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(l10n.t("access.fda.title"), systemImage: "lock.shield")
                        .font(.headline)
                    Spacer(minLength: 0)
                    fdaStatus
                }

                Text(l10n.t("access.fda.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Image(nsImage: applicationIcon)
                        .resizable()
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                        .onDrag { applicationProvider }
                        .help(l10n.t("access.fda.dragHelp"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.t("access.fda.drag"))
                            .font(.callout.weight(.medium))
                        Text(l10n.t("access.fda.dragHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )

                HStack(spacing: 8) {
                    Button(l10n.t("access.fda.open")) {
                        openPrivacySettings("Privacy_AllFiles")
                    }
                    Button(l10n.t("access.fda.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                refreshStatus()
                onRecheck?()
            } label: {
                Label(l10n.t("access.recheck"), systemImage: "arrow.clockwise")
            }

            Text(l10n.t("access.fda.statusNote"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(l10n.t("access.done")) {
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private var fdaStatus: some View {
        Label(
            fullDiskAccessGranted
                ? l10n.t("access.fda.granted")
                : l10n.t("access.fda.notGranted"),
            systemImage: fullDiskAccessGranted
                ? "checkmark.circle.fill"
                : "circle"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(fullDiskAccessGranted ? .green : .secondary)
    }

    private func refreshStatus() {
        fullDiskAccessGranted = FileManager.default.isReadableFile(
            atPath: "/Library/Application Support/com.apple.TCC/TCC.db"
        )
    }

    private func openPrivacySettings(_ anchor: String) {
        let string = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class AccessGuideWindowController {
    static let shared = AccessGuideWindowController()

    private var panel: NSPanel?

    func show(l10n: Localization, onRecheck: (() -> Void)? = nil) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = AccessGuideView(
            onClose: { [weak self] in self?.close() },
            onRecheck: onRecheck
        )
        .environment(l10n)

        let hosting = NSHostingController(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = l10n.t("access.title")
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 600, height: 540))
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
