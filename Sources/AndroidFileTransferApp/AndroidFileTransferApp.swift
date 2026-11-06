import AppKit
import SwiftUI

@main
struct AndroidFileTransferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Android File Transfer") {
            ContentView()
                .environment(model)
                .environment(model.l10n)
                .frame(minWidth: 1100, minHeight: 640)
                .task {
                    model.start()
                }
                .onDisappear {
                    model.stop()
                }
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            #if DEBUG
            CommandMenu(model.l10n.t("debug.menu")) {
                Button(model.l10n.t("debug.uploadHome")) {
                    model.debugUploadHomeFile(named: "skills-lock.json")
                }
                .keyboardShortcut("u", modifiers: [.command, .option])

                Button(model.l10n.t("debug.downloadFirst")) {
                    model.debugDownloadFirstDeviceFile()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Divider()

                Button(model.l10n.t("debug.uploadTestFolder")) {
                    model.debugUploadTestFolder()
                }

                Button(model.l10n.t("debug.downloadTestFolder")) {
                    model.debugDownloadTestFolder()
                }

                Button(model.l10n.t("debug.deleteTestFolders")) {
                    model.debugDeleteTestFoldersNow()
                }

                Button(model.l10n.t("debug.resetUSB")) {
                    model.debugResetUSBDevice()
                }

                Button(model.l10n.t("debug.disconnectDevice")) {
                    model.debugDisconnectDevice()
                }

                Button(model.l10n.t("debug.quickLookHome")) {
                    model.debugQuickLookHomeFile(named: "skills-lock.json")
                }

                Button(model.l10n.t("debug.quickLookDevice")) {
                    model.debugQuickLookFirstDeviceFile()
                }

                Button(model.l10n.t("debug.testDrag")) {
                    model.debugTestDragProvider()
                }

                Button(model.l10n.t("debug.testFolderDrag")) {
                    model.debugTestFolderDragProvider()
                }

                Button(model.l10n.t("debug.uploadLarge")) {
                    model.debugUploadLargeTestFile()
                }

                Button(model.l10n.t("debug.cancelTransfer")) {
                    model.debugCancelTransfer()
                }

                Button(model.l10n.t("debug.pauseTransfer")) {
                    model.debugPauseTransfer()
                }

                Button(model.l10n.t("debug.resumeQueue")) {
                    model.debugResumeQueue()
                }
            }
            #endif
        }

        Settings {
            SettingsView(appModel: model, l10n: model.l10n)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []
    private weak var lastMainWindow: NSWindow?
    private var didPresentInitialWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // A window restored on a disconnected display can reopen off-screen.
        // SwiftUI applies its saved frame after launch, so check when the window
        // actually becomes key (and again on activation) instead of on a timer.
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            self.lastMainWindow = window
            Self.ensureOnScreen(window)
            if !self.didPresentInitialWindow {
                self.didPresentInitialWindow = true
                self.moveToCursorScreen(window)
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            for window in NSApp.windows {
                Self.ensureOnScreen(window)
            }
        })

        // Fallback for a window that is created but never becomes key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.didPresentInitialWindow,
                  let window = NSApp.windows.first(where: {
                      $0.isVisible && $0.styleMask.contains(.titled)
                  })
            else { return }
            self.didPresentInitialWindow = true
            self.lastMainWindow = window
            self.moveToCursorScreen(window)
        }
    }

    private func moveToCursorScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              window.screen != screen
        else { return }

        let visible = screen.visibleFrame
        let width = min(window.frame.width, visible.width)
        let height = min(window.frame.height, visible.height)
        window.setFrame(NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        ), display: true)
    }

    private static func ensureOnScreen(_ window: NSWindow) {
        guard window.isVisible, window.styleMask.contains(.titled) else { return }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              !visible.intersects(window.frame)
        else { return }

        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app alive (and transfers running) when the window is closed.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            showLastWindow(moveToCursorScreen: true)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.keyWindow == nil {
            showLastWindow()
        }
    }

    private func showLastWindow(moveToCursorScreen: Bool = false) {
        let window = lastMainWindow ?? NSApp.windows.first {
            $0.styleMask.contains(.titled)
        }
        guard let window else { return }
        if moveToCursorScreen {
            self.moveToCursorScreen(window)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
