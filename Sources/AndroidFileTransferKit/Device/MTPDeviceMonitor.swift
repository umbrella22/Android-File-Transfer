import Foundation
import IOKit
import IOUSBHost

/// IOKit hotplug monitor for MTP/PTP interfaces.
///
/// Replaces the 1.5 s polling loop in the app. Attach and detach callbacks are
/// delivered on the main queue. The `service` handle in an attached interface
/// is retained by the caller (USBMTPInterface); the device manager must release
/// it after opening the interface.
public final class MTPDeviceMonitor {
    public var onAttach: ((USBMTPInterface) -> Void)?
    public var onDetach: ((USBMTPInterface?) -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0
    private var started = false
    private var knownMTPServices = Set<UInt32>()

    public init() {}

    deinit {
        stop()
    }

    public func start() {
        guard !started else { return }
        started = true

        let port = IONotificationPortCreate(kIOMainPortDefault)
        notificationPort = port
        mptLog("monitor port=\(String(describing: port)) type=\(kIOFirstMatchNotification)")

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()

        let attachDictionary = matchingDictionary()
        let attachResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            attachDictionary,
            mptAttachCallback,
            context,
            &attachIterator
        )
        mptLog("monitor attach registration=\(attachResult) iterator=\(attachIterator)")
        drainAttach(iterator: attachIterator)

        let detachDictionary = matchingDictionary()
        let detachResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            detachDictionary,
            mptDetachCallback,
            context,
            &detachIterator
        )
        mptLog("monitor detach registration=\(detachResult) iterator=\(detachIterator)")
        drainDetach(iterator: detachIterator)
    }

    public func stop() {
        guard started else { return }
        started = false

        if attachIterator != 0 {
            IOObjectRelease(attachIterator)
            attachIterator = 0
        }
        if detachIterator != 0 {
            IOObjectRelease(detachIterator)
            detachIterator = 0
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        knownMTPServices.removeAll()
    }

    fileprivate func drainAttach(iterator: io_iterator_t) {
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            count += 1
            if let info = USBDeviceEnumerator.describe(service: service),
               info.interfaceClass == 6 {
                knownMTPServices.insert(service)
                mptLog("monitor attach service=\(service) \(info.displayName)")
                DispatchQueue.main.async { [weak self] in
                    self?.onAttach?(info)
                }
            } else {
                IOObjectRelease(service)
            }
        }
        mptLog("monitor attach drain count=\(count)")
    }

    fileprivate func drainDetach(iterator: io_iterator_t) {
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            count += 1
            let info = USBDeviceEnumerator.describe(service: service)
            let isKnownMTP = knownMTPServices.remove(service) != nil
            let isMTP = (info?.interfaceClass == 6) || isKnownMTP
            mptLog("monitor detach service=\(service) \(String(describing: info?.displayName)) mtp=\(isMTP)")
            if isMTP {
                DispatchQueue.main.async { [weak self] in
                    self?.onDetach?(info)
                }
            }
            IOObjectRelease(service)
        }
        mptLog("monitor detach drain count=\(count)")
    }

    private func matchingDictionary() -> CFMutableDictionary {
        IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil,
            bcdDevice: nil,
            interfaceNumber: nil,
            configurationValue: nil,
            interfaceClass: nil,
            interfaceSubclass: nil,
            interfaceProtocol: nil,
            speed: nil,
            productIDArray: nil
        ).takeRetainedValue()
    }
}

private func mptLog(_ message: String) {
    #if DEBUG
    FileHandle.standardError.write(Data(("[MTPMonitor] " + message + "\n").utf8))
    #endif
}

private func mptAttachCallback(
    context: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let context else { return }
    let monitor = Unmanaged<MTPDeviceMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
    monitor.drainAttach(iterator: iterator)
}

private func mptDetachCallback(
    context: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let context else { return }
    let monitor = Unmanaged<MTPDeviceMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
    monitor.drainDetach(iterator: iterator)
}
