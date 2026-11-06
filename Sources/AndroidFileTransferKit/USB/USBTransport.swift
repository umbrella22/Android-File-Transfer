import Foundation
import IOKit

public enum USBTransportError: Error, LocalizedError, Equatable {
    case noMTPInterface
    case openFailed(code: Int32, message: String)
    case exclusiveAccess
    case pipeUnavailable(String)
    case ioFailed(operation: String, code: Int32)
    case timeout(operation: String)
    case shortWrite(expected: Int, actual: Int)
    case deviceDisconnected
    case closed
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .noMTPInterface:
            return "No MTP/PTP interface found"
        case let .openFailed(code, message):
            return "Failed to open USB interface (\(code)): \(message)"
        case .exclusiveAccess:
            return "The MTP interface is already claimed by another application (Image Capture, Photos, ptpcamera, or another MTP client)"
        case let .pipeUnavailable(name):
            return "USB pipe unavailable: \(name)"
        case let .ioFailed(operation, code):
            return "USB I/O failed during \(operation) (0x\(String(code, radix: 16)))"
        case let .timeout(operation):
            return "USB I/O timed out during \(operation)"
        case let .shortWrite(expected, actual):
            return "Short USB write: expected \(expected) bytes, wrote \(actual)"
        case .deviceDisconnected:
            return "The MTP device was disconnected"
        case .closed:
            return "The USB transport is closed"
        case let .protocolViolation(message):
            return "USB protocol violation: \(message)"
        }
    }
}

public enum USBEndpointType: UInt8, Sendable, CustomStringConvertible {
    case control = 0
    case isochronous = 1
    case bulk = 2
    case interrupt = 3

    public var description: String {
        switch self {
        case .control: return "control"
        case .isochronous: return "isochronous"
        case .bulk: return "bulk"
        case .interrupt: return "interrupt"
        }
    }
}

public struct USBEndpointInfo: Sendable, Equatable {
    public let address: UInt8
    public let type: USBEndpointType
    public let maxPacketSize: Int
    public let interval: UInt8

    public init(address: UInt8, type: USBEndpointType, maxPacketSize: Int, interval: UInt8) {
        self.address = address
        self.type = type
        self.maxPacketSize = maxPacketSize
        self.interval = interval
    }

    public var isIn: Bool { (address & 0x80) != 0 }
    public var endpointNumber: UInt8 { address & 0x0F }
}

/// Metadata for an MTP/PTP interface in the IORegistry.
public struct USBMTPInterface: Sendable, Equatable {
    /// The io_service_t for the IOUSBHostInterface. It is a UInt32 handle and
    /// is only valid until the matching service is terminated.
    public let service: UInt32
    public let vendorID: Int
    public let productID: Int
    public let manufacturer: String?
    public let product: String?
    public let serialNumber: String?
    public let interfaceNumber: Int
    public let configurationValue: Int
    public let interfaceClass: Int
    public let interfaceSubclass: Int
    public let interfaceProtocol: Int
    public let locationID: UInt32?

    public init(
        service: UInt32,
        vendorID: Int,
        productID: Int,
        manufacturer: String?,
        product: String?,
        serialNumber: String?,
        interfaceNumber: Int,
        configurationValue: Int,
        interfaceClass: Int,
        interfaceSubclass: Int,
        interfaceProtocol: Int,
        locationID: UInt32?
    ) {
        self.service = service
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
        self.interfaceNumber = interfaceNumber
        self.configurationValue = configurationValue
        self.interfaceClass = interfaceClass
        self.interfaceSubclass = interfaceSubclass
        self.interfaceProtocol = interfaceProtocol
        self.locationID = locationID
    }

    public var displayName: String {
        let name = [manufacturer, product].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? String(format: "USB %04x:%04x", vendorID, productID) : name
    }
}

public protocol USBTransport: AnyObject {
    var isOpen: Bool { get }
    var bulkInMaxPacketSize: Int { get }
    var bulkOutMaxPacketSize: Int { get }

    func open() async throws
    func close()
    func write(_ data: Data, timeout: TimeInterval) async throws
    func read(maxLength: Int, timeout: TimeInterval) async throws -> Data
    func readEvent(maxLength: Int) async throws -> Data

    /// Abort any in-flight bulk/interrupt transfer. The MTP session is no
    /// longer usable afterwards and must be closed/reopened.
    func abort()

    /// Best-effort cleanup for containers left in the bulk-in pipe by a
    /// previous client that crashed mid-transaction. Called before OpenSession.
    func drainStale() async
}

public extension USBTransport {
    func abort() {}
    func drainStale() async {}
}
