import Foundation
import IOUSBHost
import IOKit

/// USB transport backed by Apple's IOUSBHost framework.
///
/// This is the only place that touches IOUSBHost. The MTP layer sees a
/// simple async byte-pipe interface, so a libusb or mock transport can be
/// swapped in without changing the protocol code.
public final class IOUSBHostTransport: USBTransport {
    private let interfaceInfo: USBMTPInterface
    private var hostInterface: IOUSBHostInterface?
    private var bulkIn: IOUSBHostPipe?
    private var bulkOut: IOUSBHostPipe?
    private var interruptIn: IOUSBHostPipe?

    public private(set) var bulkInMaxPacketSize: Int = 512
    public private(set) var bulkOutMaxPacketSize: Int = 512

    public var isOpen: Bool { hostInterface != nil }

    public init(interfaceInfo: USBMTPInterface) {
        self.interfaceInfo = interfaceInfo
    }

    /// Resets the parent USB device instead of only closing the MTP session.
    /// This is the recovery path for a device whose MTP server is wedged after
    /// an interrupted large transfer. The interface service must not have an
    /// active IOUSBHost user client at this point.
    public static func resetDevice(for interfaceInfo: USBMTPInterface) throws {
        var parent: io_service_t = 0
        let result = IORegistryEntryGetParentEntry(
            io_service_t(interfaceInfo.service),
            kIOServicePlane,
            &parent
        )
        guard result == KERN_SUCCESS, parent != 0 else {
            throw USBTransportError.openFailed(
                code: result,
                message: "interface has no parent IOUSBHostDevice"
            )
        }
        defer { IOObjectRelease(parent) }

        guard IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 else {
            throw USBTransportError.openFailed(
                code: -1,
                message: "interface parent is not an IOUSBHostDevice"
            )
        }

        do {
            let device = try IOUSBHostDevice(
                __ioService: parent,
                options: [],
                queue: nil,
                interestHandler: nil
            )
            defer { device.destroy() }
            try device.reset()
        } catch let error as NSError {
            throw USBTransportError.openFailed(
                code: Int32(error.code),
                message: error.localizedDescription
            )
        }
    }

    deinit {
        close()
    }

    public func open() async throws {
        guard hostInterface == nil else { return }

        do {
            let interface = try IOUSBHostInterface(
                __ioService: io_service_t(interfaceInfo.service),
                options: [],
                queue: nil,
                interestHandler: nil
            )
            hostInterface = interface
            try configurePipes(on: interface)
        } catch let error as NSError {
            if Int32(error.code) == kIOReturnExclusiveAccess {
                throw USBTransportError.exclusiveAccess
            }
            throw USBTransportError.openFailed(
                code: Int32(error.code),
                message: error.localizedDescription
            )
        } catch {
            throw USBTransportError.openFailed(code: -1, message: String(describing: error))
        }
    }

    public func close() {
        bulkIn = nil
        bulkOut = nil
        interruptIn = nil
        hostInterface?.destroy()
        hostInterface = nil
    }

    public func write(_ data: Data, timeout: TimeInterval) async throws {
        guard let bulkOut else {
            throw isOpen ? USBTransportError.pipeUnavailable("bulk OUT") : USBTransportError.closed
        }

        let buffer: NSMutableData? = data.isEmpty ? nil : NSMutableData(data: data)
        let (status, transferred) = try await enqueue(
            pipe: bulkOut,
            data: buffer,
            timeout: timeout
        )
        try check(status, operation: "bulk write")
        guard transferred == data.count else {
            throw USBTransportError.shortWrite(expected: data.count, actual: transferred)
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        guard let bulkIn else {
            throw isOpen ? USBTransportError.pipeUnavailable("bulk IN") : USBTransportError.closed
        }
        guard maxLength > 0 else { return Data() }
        guard let buffer = NSMutableData(length: maxLength) else {
            throw USBTransportError.ioFailed(operation: "bulk read allocation", code: -1)
        }

        let (status, transferred) = try await enqueue(
            pipe: bulkIn,
            data: buffer,
            timeout: timeout
        )
        try check(status, operation: "bulk read")
        return Data(bytes: buffer.bytes, count: transferred)
    }

    public func readEvent(maxLength: Int) async throws -> Data {
        guard let interruptIn else {
            throw USBTransportError.pipeUnavailable("interrupt IN")
        }
        guard maxLength > 0 else { return Data() }
        guard let buffer = NSMutableData(length: maxLength) else {
            throw USBTransportError.ioFailed(operation: "interrupt read allocation", code: -1)
        }

        // IOUSBHost requires a zero timeout for interrupt pipes.
        let (status, transferred) = try await enqueue(
            pipe: interruptIn,
            data: buffer,
            timeout: 0
        )
        try check(status, operation: "interrupt read")
        return Data(bytes: buffer.bytes, count: transferred)
    }

    public func abort() {
        try? bulkIn?.__abort(with: .synchronous)
        try? bulkOut?.__abort(with: .synchronous)
        try? interruptIn?.__abort(with: .synchronous)
    }

    /// A previous process can die between a command and its response, leaving
    /// containers in the bulk-in pipe. Drain them and reset both endpoints so
    /// the next OpenSession does not mistake stale data for its own reply.
    public func drainStale() async {
        guard hostInterface != nil else { return }

        var iterations = 0
        while iterations < 64 {
            do {
                let data = try await read(maxLength: 64 * 1024, timeout: 0.25)
                if data.isEmpty { break }
                iterations += 1
            } catch {
                break
            }
        }

        try? bulkIn?.__abort(with: .synchronous)
        try? bulkOut?.__abort(with: .synchronous)
        try? bulkIn?.clearStall()
        try? bulkOut?.clearStall()
    }

    // MARK: - Descriptors and pipes

    private func configurePipes(on interface: IOUSBHostInterface) throws {
        let configuration = interface.configurationDescriptor
        let interfaceDescriptor = interface.interfaceDescriptor

        var current: UnsafePointer<IOUSBEndpointDescriptor>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(
            configuration,
            interfaceDescriptor,
            descriptorHeader(current)
        ) {
            defer { current = endpoint }
            let descriptor = endpoint.pointee
            let endpointType = USBEndpointType(rawValue: descriptor.bmAttributes & 0x03)
            let maxPacketSize = Int(descriptor.wMaxPacketSize & 0x07FF)
            let isIn = (descriptor.bEndpointAddress & 0x80) != 0

            switch (endpointType, isIn) {
            case (.bulk, true):
                bulkIn = try interface.copyPipe(withAddress: Int(descriptor.bEndpointAddress))
                bulkInMaxPacketSize = max(1, maxPacketSize)

            case (.bulk, false):
                bulkOut = try interface.copyPipe(withAddress: Int(descriptor.bEndpointAddress))
                bulkOutMaxPacketSize = max(1, maxPacketSize)

            case (.interrupt, true):
                // Prefer the first interrupt IN endpoint; it is the MTP event pipe.
                if interruptIn == nil {
                    interruptIn = try interface.copyPipe(withAddress: Int(descriptor.bEndpointAddress))
                }

            default:
                break
            }
        }

        if bulkIn == nil {
            throw USBTransportError.pipeUnavailable("bulk IN (PTP data)")
        }
        if bulkOut == nil {
            throw USBTransportError.pipeUnavailable("bulk OUT (PTP command)")
        }
    }

    private func descriptorHeader(
        _ endpoint: UnsafePointer<IOUSBEndpointDescriptor>?
    ) -> UnsafePointer<IOUSBDescriptorHeader>? {
        guard let endpoint else { return nil }
        return UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
    }

    private func enqueue(
        pipe: IOUSBHostPipe,
        data: NSMutableData?,
        timeout: TimeInterval
    ) async throws -> (IOReturn, Int) {
        do {
            return try await pipe.enqueueIORequest(
                with: data,
                completionTimeout: timeout
            )
        } catch {
            // "Unable to enqueue IO" usually means the endpoint was left
            // stalled by a previous client. Reset it and retry once instead
            // of forcing the user to unplug the device.
            try? pipe.__abort(with: .synchronous)
            try? pipe.clearStall()
            return try await pipe.enqueueIORequest(
                with: data,
                completionTimeout: timeout
            )
        }
    }

    private func check(_ status: IOReturn, operation: String) throws {
        guard status == kIOReturnSuccess else {
            switch status {
            case kIOReturnTimeout, kIOReturnNotResponding:
                throw USBTransportError.timeout(operation: operation)
            case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnDeviceError:
                throw USBTransportError.deviceDisconnected
            default:
                throw USBTransportError.ioFailed(operation: operation, code: status)
            }
        }
    }
}
