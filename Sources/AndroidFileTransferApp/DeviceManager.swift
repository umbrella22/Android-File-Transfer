import Foundation
import IOKit
import AndroidFileTransferKit
import Observation

struct StorageItem: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let freeSpace: UInt64
    let maxCapacity: UInt64

    var freeSpaceText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: freeSpace))
    }
}

@MainActor
@Observable
final class DeviceManager {
    private(set) var interfaceInfo: USBMTPInterface?
    private(set) var deviceInfo: PTPDeviceInfo?
    private(set) var storages: [StorageItem] = []
    private(set) var session: MTPDeviceSession?
    private(set) var isConnecting = false
    var errorMessage: String?

    private let monitor = MTPDeviceMonitor()
    private var isMonitoring = false
    private var reconnectTask: Task<Void, Never>?

    var isConnected: Bool { session != nil }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitor.onAttach = { [weak self] info in
            Task { @MainActor in
                await self?.handleAttach(info)
            }
        }
        monitor.onDetach = { [weak self] _ in
            Task { @MainActor in
                await self?.handleDetach()
            }
        }
        monitor.start()

        // Fallback for the initial enumeration in case IOKit's first-match
        // iterator is late or the notification dictionary doesn't arm on this
        // macOS build. The monitor still handles subsequent attach/detach.
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func stop() {
        isMonitoring = false
        reconnectTask?.cancel()
        monitor.stop()
        Task { await self.disconnect() }
    }

    private func handleAttach(_ info: USBMTPInterface) async {
        // Do not trust a non-nil session here: a physical unplug can beat the
        // detach callback, leaving a stale session. Re-enumerate instead so a
        // still-present active interface is kept and a stale one is replaced.
        IOObjectRelease(io_service_t(info.service))
        await refresh()
    }

    private func handleDetach() async {
        guard session != nil || isConnecting else { return }
        await disconnect()
        scheduleReconnect()
    }

    func refresh() async {
        // Do not enumerate while a connection is in flight: releasing the
        // service handles here would race with IOUSBHostTransport.open().
        guard !isConnecting else { return }

        let interfaces = USBDeviceEnumerator.findMTPInterfaces()

        if let active = interfaceInfo {
            let stillPresent = interfaces.contains { Self.matches($0, active) }
            if stillPresent {
                release(interfaces)
                return
            }
            // The old session is stale (detach was missed or the device
            // re-enumerated). Fall through and connect to the new interface.
            await disconnect()
        }

        guard session == nil, !isConnecting, let first = interfaces.first else {
            release(interfaces)
            return
        }

        for interface in interfaces.dropFirst() {
            IOObjectRelease(io_service_t(interface.service))
        }
        await connect(to: first)
    }

    private func connect(to info: USBMTPInterface) async {
        isConnecting = true
        errorMessage = nil
        var serviceReleased = false

        defer { isConnecting = false }

        do {
            let transport = IOUSBHostTransport(interfaceInfo: info)
            try await transport.open()
            IOObjectRelease(io_service_t(info.service))
            serviceReleased = true

            let session = MTPDeviceSession(transport: transport)
            do {
                let device = try await session.openSession()
                let storages = try await session.storages()
                self.interfaceInfo = info
                self.session = session
                self.deviceInfo = device
                self.storages = storages.map {
                    StorageItem(
                        id: $0.id,
                        name: $0.info.storageDescription,
                        freeSpace: $0.info.freeSpaceInBytes,
                        maxCapacity: $0.info.maxCapacity
                    )
                }
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
            } catch {
                await session.closeSession()
                throw error
            }
        } catch {
            if !serviceReleased {
                IOObjectRelease(io_service_t(info.service))
            }
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        if let session {
            await session.closeSession()
        }
        session = nil
        interfaceInfo = nil
        deviceInfo = nil
        storages = []
    }

    /// Closes a possibly stale session and re-enumerates immediately.
    func reconnect() async {
        await disconnect()
        await refresh()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            for delay in [0.4, 1.0, 2.5] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.session != nil || self.isConnecting { return }
                await self.refresh()
                if self.session != nil { return }
            }
        }
    }

    /// Resets the parent USB device and lets the IOKit monitor re-enumerate it.
    /// Used to recover a wedged MTP server after a mid-transfer abort.
    func resetUSBForRecovery() {
        Task {
            let interfaces = USBDeviceEnumerator.findMTPInterfaces()
            if let first = interfaces.first {
                try? IOUSBHostTransport.resetDevice(for: first)
            }
            for interface in interfaces {
                IOObjectRelease(io_service_t(interface.service))
            }
        }
    }

    /// Development helper: USB reset re-enumerates the phone, which exercises
    /// the IOKit detach/attach path without physically unplugging the cable.
    func debugResetUSBDevice() {
        Task {
            await disconnect()
            resetUSBForRecovery()
        }
    }

    private func release(_ interfaces: [USBMTPInterface]) {
        for interface in interfaces {
            IOObjectRelease(io_service_t(interface.service))
        }
    }

    private static func matches(_ lhs: USBMTPInterface, _ rhs: USBMTPInterface) -> Bool {
        if let leftSerial = lhs.serialNumber, let rightSerial = rhs.serialNumber,
           !leftSerial.isEmpty, !rightSerial.isEmpty {
            return leftSerial == rightSerial
        }
        return lhs.vendorID == rhs.vendorID
            && lhs.productID == rhs.productID
            && lhs.interfaceNumber == rhs.interfaceNumber
            && lhs.locationID == rhs.locationID
    }
}

@MainActor
@Observable
final class TransferStatus {
    private let l10n: Localization

    init(l10n: Localization) {
        self.l10n = l10n
    }

    private(set) var isActive = false
    private(set) var title = ""
    private(set) var detail = ""
    private(set) var fraction: Double?
    private(set) var errorMessage: String?
    private(set) var isCompleted = false
    private(set) var isPaused = false

    private var total: Int64?
    private var dismissTask: Task<Void, Never>?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    func start(title: String, detail: String = "", total: Int64?) {
        dismissTask?.cancel()
        self.title = title
        self.detail = detail
        self.total = total
        self.fraction = total.map { _ in 0 }
        self.errorMessage = nil
        self.isCompleted = false
        self.isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
        isActive = true
    }

    func update(written: Int64, currentFile: String? = nil) {
        update(completedBytes: 0, currentBytes: written, detail: currentFile)
    }

    func update(completedBytes: Int64, currentBytes: Int64, detail: String? = nil) {
        if let total, total > 0 {
            fraction = min(1, Double(completedBytes + currentBytes) / Double(total))
        }
        if let detail, !detail.isEmpty {
            self.detail = detail
        }
    }

    func pause() {
        guard isActive, !isCompleted, !isPaused else { return }
        isPaused = true
        detail = l10n.t("transfer.paused")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if detail == l10n.t("transfer.paused") {
            detail = ""
        }
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func waitIfPaused() async {
        while isPaused {
            await withCheckedContinuation { continuation in
                pauseContinuation = continuation
            }
        }
    }

    func requestCancel() {
        guard isActive else { return }
        detail = l10n.t("transfer.canceling")
    }

    func canceled() {
        dismissTask?.cancel()
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
        title = l10n.t("transfer.canceled")
        detail = ""
        fraction = nil
        errorMessage = nil
        isCompleted = false
        isActive = false
    }

    func finish(detail: String = "Done") {
        dismissTask?.cancel()
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
        self.title = l10n.t("transfer.done")
        self.detail = detail
        fraction = 1
        errorMessage = nil
        isCompleted = true
        isActive = true
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.isActive = false
            self?.isCompleted = false
        }
    }

    func fail(_ error: Error) {
        dismissTask?.cancel()
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
        errorMessage = error.localizedDescription
        isCompleted = false
        isActive = false
    }

    func dismissError() {
        errorMessage = nil
    }
}
