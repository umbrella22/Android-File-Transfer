import Foundation

/// A PTP/MTP container. The first 12 bytes are the container header
/// (length, type, code, transaction ID); command/response/event containers
/// carry up to five 32-bit parameters after the header, while data containers
/// carry an opaque payload.
public struct PTPContainer: Equatable, Sendable {
    public var type: PTPContainerType
    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]
    public var payload: Data

    public init(
        type: PTPContainerType,
        code: UInt16,
        transactionID: UInt32,
        parameters: [UInt32] = [],
        payload: Data = Data()
    ) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
        self.payload = payload
    }

    public var encodedLength: UInt32 {
        UInt32(12 + parameters.count * 4 + payload.count)
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        let length = encodedLength
        writer.writeUInt32(length)
        writer.writeUInt16(type.rawValue)
        writer.writeUInt16(code)
        writer.writeUInt32(transactionID)
        for parameter in parameters {
            writer.writeUInt32(parameter)
        }
        writer.writeBytes(payload)
        return Data(writer.bytes)
    }

    public static func decode(_ data: Data) throws -> PTPContainer {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else {
            throw PTPDecodingError.truncated(offset: 0, needed: 12, available: bytes.count)
        }

        var reader = ByteReader(bytes)
        let length = try reader.readUInt32()
        guard length >= 12, Int(length) <= bytes.count else {
            throw PTPDecodingError.invalidContainerLength(length)
        }

        let typeRaw = try reader.readUInt16()
        guard let type = PTPContainerType(rawValue: typeRaw) else {
            throw PTPDecodingError.unexpectedContainerType(.command, expected: .response)
        }
        let code = try reader.readUInt16()
        let transactionID = try reader.readUInt32()

        let bodyLength = Int(length) - 12
        if type == .data {
            let payload = try reader.readBytes(bodyLength)
            return PTPContainer(
                type: type,
                code: code,
                transactionID: transactionID,
                parameters: [],
                payload: Data(payload)
            )
        }

        let parameterCount = bodyLength / 4
        var parameters = [UInt32]()
        parameters.reserveCapacity(parameterCount)
        for _ in 0 ..< parameterCount {
            parameters.append(try reader.readUInt32())
        }
        return PTPContainer(
            type: type,
            code: code,
            transactionID: transactionID,
            parameters: parameters
        )
    }
}

public struct PTPContainerHeader: Equatable, Sendable {
    public let length: UInt32
    public let type: PTPContainerType
    public let code: UInt16
    public let transactionID: UInt32

    public init(length: UInt32, type: PTPContainerType, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }

    public static func decode(_ data: Data) throws -> PTPContainerHeader {
        guard data.count >= 12 else {
            throw PTPDecodingError.truncated(offset: 0, needed: 12, available: data.count)
        }
        var reader = ByteReader(data)
        let length = try reader.readUInt32()
        let typeRaw = try reader.readUInt16()
        guard let type = PTPContainerType(rawValue: typeRaw) else {
            throw PTPDecodingError.invalidContainerLength(length)
        }
        let code = try reader.readUInt16()
        let transactionID = try reader.readUInt32()
        guard length >= 12 else {
            throw PTPDecodingError.invalidContainerLength(length)
        }
        return PTPContainerHeader(
            length: length,
            type: type,
            code: code,
            transactionID: transactionID
        )
    }
}
