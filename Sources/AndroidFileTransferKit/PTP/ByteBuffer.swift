import Foundation

public enum PTPDecodingError: Error, LocalizedError, Equatable {
    case truncated(offset: Int, needed: Int, available: Int)
    case invalidStringLength(Int)
    case invalidContainerLength(UInt32)
    case unexpectedContainerType(PTPContainerType, expected: PTPContainerType)
    case transactionMismatch(expected: UInt32, actual: UInt32)

    public var errorDescription: String? {
        switch self {
        case let .truncated(offset, needed, available):
            return "Truncated PTP data at offset \(offset): needed \(needed), available \(available)"
        case let .invalidStringLength(length):
            return "Invalid PTP string length \(length)"
        case let .invalidContainerLength(length):
            return "Invalid PTP container length \(length)"
        case let .unexpectedContainerType(actual, expected):
            return "Unexpected PTP container type \(actual), expected \(expected)"
        case let .transactionMismatch(expected, actual):
            return "PTP transaction mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// Little-endian reader for PTP/MTP datasets.
public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.bytes = Array(data)
        self.offset = 0
    }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readUInt16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    public mutating func readUInt32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    public mutating func readUInt64() throws -> UInt64 {
        try require(8)
        let low = UInt64(try readUInt32())
        let high = UInt64(try readUInt32())
        return low | (high << 32)
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try require(count)
        defer { offset += count }
        return Array(bytes[offset ..< offset + count])
    }

    /// MTP/PTP strings are a UInt8 length (UTF-16 code units, including the
    /// null terminator) followed by little-endian UTF-16 code units.
    public mutating func readString() throws -> String {
        let length = Int(try readUInt8())
        guard length > 0 else { return "" }

        let raw = try readBytes(length * 2)
        var units = [UInt16]()
        units.reserveCapacity(length)
        var index = 0
        while index < raw.count {
            units.append(UInt16(raw[index]) | (UInt16(raw[index + 1]) << 8))
            index += 2
        }
        if units.last == 0 {
            units.removeLast()
        }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func readUInt16Array() throws -> [UInt16] {
        let count = Int(try readUInt32())
        var values = [UInt16]()
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            values.append(try readUInt16())
        }
        return values
    }

    public mutating func readUInt32Array() throws -> [UInt32] {
        let count = Int(try readUInt32())
        var values = [UInt32]()
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            values.append(try readUInt32())
        }
        return values
    }

    private func require(_ count: Int) throws {
        guard count >= 0, remaining >= count else {
            throw PTPDecodingError.truncated(
                offset: offset,
                needed: count,
                available: remaining
            )
        }
    }
}

/// Little-endian writer for PTP/MTP datasets.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    public mutating func writeUInt64(_ value: UInt64) {
        writeUInt32(UInt32(truncatingIfNeeded: value))
        writeUInt32(UInt32(truncatingIfNeeded: value >> 32))
    }

    public mutating func writeBytes(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    public mutating func writeBytes(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }

    /// Writes a MTP/PTP UTF-16LE string with a one-byte length prefix.
    public mutating func writeString(_ value: String) throws {
        guard !value.isEmpty else {
            writeUInt8(0)
            return
        }

        var units = Array(value.utf16)
        units.append(0)
        guard units.count <= 255 else {
            throw PTPDecodingError.invalidStringLength(units.count)
        }

        writeUInt8(UInt8(units.count))
        for unit in units {
            writeUInt16(unit)
        }
    }

    public mutating func writeUInt16Array(_ values: [UInt16]) {
        writeUInt32(UInt32(values.count))
        for value in values {
            writeUInt16(value)
        }
    }

    public mutating func writeUInt32Array(_ values: [UInt32]) {
        writeUInt32(UInt32(values.count))
        for value in values {
            writeUInt32(value)
        }
    }
}
