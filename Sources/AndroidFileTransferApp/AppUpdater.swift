import Combine
import Foundation
import Sparkle

/// Sparkle owns the consent prompt, update preferences and signature verification.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    private var controller: SPUStandardUpdaterController?
    private var busy: () -> Bool = { false }
    private var pendingInstall: (() -> Void)?

    func start(whileBusy busy: @escaping () -> Bool) {
        // swift run and XCTest do not have the packaged application's feed or public key.
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        self.busy = busy
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticDownloads)
        controller.startUpdater()
    }

    func check() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller?.updater.automaticallyDownloadsUpdates = enabled }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard busy() else { return false }
        pendingInstall = installHandler
        return true
    }

    func resumeInstallIfIdle() {
        guard !busy(), let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }
}
