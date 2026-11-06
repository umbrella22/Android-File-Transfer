import Foundation
import AndroidFileTransferKit

/// In-memory MTP device for tests. It implements just enough of the protocol
/// to exercise MTPDeviceSession's transaction and dataset handling.
final class MockMTPTransport: USBTransport {
    struct FileEntry {
        let handle: UInt32
        let info: PTPObjectInfo
        let contents: Data
    }

    var isOpen = false
    let bulkInMaxPacketSize = 512
    let bulkOutMaxPacketSize = 512

    let deviceInfo: PTPDeviceInfo
    let storageID: UInt32
    let storageInfo: PTPStorageInfo
    let files: [FileEntry]
    let rootHandles: [UInt32]

    /// When true, GetObjectHandles answers with a bare OK response instead of
    /// an empty data container. Some Android virtual folders do this.
    var bareObjectHandles = false

    /// When true, GetObject returns a data container whose length is
    /// 0xFFFFFFFF, exercising the unknown-length streaming path.
    var useUnknownLengthForGetObject = false

    private var incoming: [Data] = []
    private var pendingData: PendingData?
    private var nextHandle: UInt32

    private struct PendingData {
        let operation: PTPOperationCode
        let transactionID: UInt32
        let parameters: [UInt32]
        var expectedPayloadLength: Int?
        var receivedPayloadLength: Int = 0
    }

    init(
        deviceInfo: PTPDeviceInfo,
        storageID: UInt32,
        storageInfo: PTPStorageInfo,
        files: [FileEntry],
        extraRootHandles: [UInt32] = []
    ) {
        self.deviceInfo = deviceInfo
        self.storageID = storageID
        self.storageInfo = storageInfo
        self.files = files
        self.rootHandles = files.map(\.handle) + extraRootHandles
        self.nextHandle = (files.map(\.handle).max() ?? 0x100) + 1
    }

    func open() async throws {
        isOpen = true
    }

    func close() {
        isOpen = false
        incoming.removeAll()
        pendingData = nil
    }

    func write(_ data: Data, timeout: TimeInterval) async throws {
        guard isOpen else { throw USBTransportError.closed }

        if var pending = pendingData {
            if pending.expectedPayloadLength == nil {
                let header = try PTPContainerHeader.decode(data)
                pending.expectedPayloadLength = Int(header.length) - 12
                let payload = data.dropFirst(12)
                pending.receivedPayloadLength = payload.count
            } else {
                pending.receivedPayloadLength += data.count
            }

            if let expected = pending.expectedPayloadLength,
               pending.receivedPayloadLength >= expected {
                finishData(pending)
                pendingData = nil
            } else {
                pendingData = pending
            }
            return
        }

        let container = try PTPContainer.decode(data)
        guard container.type == .command else { return }
        guard let operation = PTPOperationCode(rawValue: container.code) else { return }

        switch operation {
        case .openSession:
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .closeSession:
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .getDeviceInfo:
            enqueueData(
                operation: operation,
                transactionID: container.transactionID,
                payload: try Self.encode(deviceInfo)
            )
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .getStorageIDs:
            var writer = ByteWriter()
            writer.writeUInt32Array([storageID])
            enqueueData(
                operation: operation,
                transactionID: container.transactionID,
                payload: Data(writer.bytes)
            )
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .getStorageInfo:
            enqueueData(
                operation: operation,
                transactionID: container.transactionID,
                payload: try Self.encode(storageInfo)
            )
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .getObjectHandles:
            if bareObjectHandles {
                enqueueResponse(transactionID: container.transactionID, code: .ok)
                return
            }
            var writer = ByteWriter()
            writer.writeUInt32Array(rootHandles)
            enqueueData(
                operation: operation,
                transactionID: container.transactionID,
                payload: Data(writer.bytes)
            )
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .getObjectInfo:
            guard let handle = container.parameters.first,
                  let file = files.first(where: { $0.handle == handle })
            else {
                enqueueResponse(transactionID: container.transactionID, code: .invalidObjectHandle)
                return
            }
            enqueueData(
                operation: operation,
                transactionID: container.transactionID,
                payload: try file.info.encoded()
            )
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .getObject:
            guard let handle = container.parameters.first,
                  let file = files.first(where: { $0.handle == handle })
            else {
                enqueueResponse(transactionID: container.transactionID, code: .invalidObjectHandle)
                return
            }
            if useUnknownLengthForGetObject {
                var writer = ByteWriter()
                writer.writeUInt32(0xFFFF_FFFF)
                writer.writeUInt16(PTPContainerType.data.rawValue)
                writer.writeUInt16(operation.rawValue)
                writer.writeUInt32(container.transactionID)
                writer.writeBytes(file.contents)
                incoming.append(Data(writer.bytes))
                enqueueResponse(transactionID: container.transactionID, code: .ok)
                return
            }
            enqueueData(
                operation: operation,
                transactionID: container.transactionID,
                payload: file.contents
            )
            enqueueResponse(transactionID: container.transactionID, code: .ok)

        case .sendObjectInfo, .sendObject, .setObjectPropValue:
            pendingData = PendingData(
                operation: operation,
                transactionID: container.transactionID,
                parameters: container.parameters
            )

        default:
            enqueueResponse(transactionID: container.transactionID, code: .operationNotSupported)
        }
    }

    func read(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        guard isOpen else { throw USBTransportError.closed }
        guard maxLength > 0, !incoming.isEmpty else { return Data() }

        // Return at most one enqueued container per call, as a real USB
        // transfer would. Do not concatenate a response onto file data.
        let current = incoming[0]
        let count = min(maxLength, current.count)
        let result = current.prefix(count)
        if count == current.count {
            incoming.removeFirst()
        } else {
            incoming[0] = Data(current.dropFirst(count))
        }
        return Data(result)
    }

    func readEvent(maxLength: Int) async throws -> Data {
        throw USBTransportError.pipeUnavailable("mock interrupt IN")
    }

    // MARK: - Responses

    private func finishData(_ pending: PendingData) {
        switch pending.operation {
        case .sendObjectInfo:
            let storageID = pending.parameters.first ?? self.storageID
            let parent = pending.parameters.dropFirst().first ?? 0xFFFF_FFFF
            let handle = nextHandle
            nextHandle += 1
            enqueueResponse(
                transactionID: pending.transactionID,
                code: .ok,
                parameters: [storageID, parent, handle]
            )

        case .sendObject, .setObjectPropValue:
            enqueueResponse(transactionID: pending.transactionID, code: .ok)

        default:
            enqueueResponse(transactionID: pending.transactionID, code: .operationNotSupported)
        }
    }

    private func enqueueData(
        operation: PTPOperationCode,
        transactionID: UInt32,
        payload: Data
    ) {
        var writer = ByteWriter()
        writer.writeUInt32(UInt32(12 + payload.count))
        writer.writeUInt16(PTPContainerType.data.rawValue)
        writer.writeUInt16(operation.rawValue)
        writer.writeUInt32(transactionID)
        writer.writeBytes(payload)
        incoming.append(Data(writer.bytes))
    }

    private func enqueueResponse(
        transactionID: UInt32,
        code: PTPResponseCode,
        parameters: [UInt32] = []
    ) {
        let container = PTPContainer(
            type: .response,
            code: code.rawValue,
            transactionID: transactionID,
            parameters: parameters
        )
        incoming.append(container.encoded())
    }

    // MARK: - Dataset builders

    private static func encode(_ info: PTPDeviceInfo) throws -> Data {
        var writer = ByteWriter()
        writer.writeUInt16(info.standardVersion)
        writer.writeUInt32(info.vendorExtensionID)
        writer.writeUInt16(info.mtpVersion)
        try writer.writeString(info.mtpExtension)
        writer.writeUInt16(info.functionalMode)
        writer.writeUInt16Array(info.operationsSupported)
        writer.writeUInt16Array(info.eventsSupported)
        writer.writeUInt16Array(info.devicePropertiesSupported)
        writer.writeUInt16Array(info.captureFormats)
        writer.writeUInt16Array(info.playbackFormats)
        try writer.writeString(info.manufacturer)
        try writer.writeString(info.model)
        try writer.writeString(info.deviceVersion)
        try writer.writeString(info.serialNumber)
        return Data(writer.bytes)
    }

    private static func encode(_ info: PTPStorageInfo) throws -> Data {
        var writer = ByteWriter()
        writer.writeUInt16(info.storageType)
        writer.writeUInt16(info.filesystemType)
        writer.writeUInt16(info.accessCapability)
        writer.writeUInt64(info.maxCapacity)
        writer.writeUInt64(info.freeSpaceInBytes)
        writer.writeUInt32(info.freeSpaceInImages)
        try writer.writeString(info.storageDescription)
        try writer.writeString(info.volumeLabel)
        return Data(writer.bytes)
    }
}
