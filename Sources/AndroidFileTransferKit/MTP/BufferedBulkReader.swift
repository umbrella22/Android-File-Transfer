import Foundation

/// Buffers bulk-IN data so callers can read exact container sizes without
/// worrying about USB packet boundaries. This mirrors the "separate header"
/// handling required by some MTP devices.
final class BufferedBulkReader {
    private let transport: USBTransport
    private let defaultReadSize: Int
    private var buffer = Data()

    init(transport: USBTransport, defaultReadSize: Int = 64 * 1024) {
        self.transport = transport
        self.defaultReadSize = max(512, defaultReadSize)
    }

    var bufferedByteCount: Int { buffer.count }

    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        guard count >= 0 else {
            throw MTPError.invalidResponse("negative read length \(count)")
        }
        guard count > 0 else { return Data() }

        var zeroLengthReads = 0
        while buffer.count < count {
            let request = max(defaultReadSize, count - buffer.count)
            let chunk = try await transport.read(maxLength: request, timeout: timeout)
            if chunk.isEmpty {
                // A zero-length packet is legal at the end of a bulk data
                // phase. Skip a few before declaring the stream dead.
                zeroLengthReads += 1
                if zeroLengthReads > 4 {
                    throw MTPError.unexpectedEndOfStream
                }
                continue
            }
            zeroLengthReads = 0
            buffer.append(chunk)
        }

        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    func readUpTo(_ maxLength: Int, timeout: TimeInterval) async throws -> Data {
        guard maxLength > 0 else { return Data() }
        if !buffer.isEmpty {
            let count = min(buffer.count, maxLength)
            let result = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(result)
        }
        return try await transport.read(maxLength: maxLength, timeout: timeout)
    }

    /// Like readUpTo, but distinguishes a short USB transfer from a partial
    /// drain of the internal buffer. Unknown-length data phases must continue
    /// until the device itself sends a short packet or ZLP, not merely because
    /// the buffer happened to contain less than one chunk.
    func readChunk(
        maxLength: Int,
        timeout: TimeInterval
    ) async throws -> (data: Data, isShortTransfer: Bool) {
        guard maxLength > 0 else { return (Data(), true) }
        if !buffer.isEmpty {
            let count = min(buffer.count, maxLength)
            let result = buffer.prefix(count)
            buffer.removeFirst(count)
            return (Data(result), false)
        }
        let chunk = try await transport.read(maxLength: maxLength, timeout: timeout)
        return (chunk, chunk.count < maxLength)
    }

    func readHeader(timeout: TimeInterval) async throws -> PTPContainerHeader {
        let data = try await readExactly(12, timeout: timeout)
        return try PTPContainerHeader.decode(data)
    }

    func readResponse(
        expectedTransactionID: UInt32,
        operation: PTPOperationCode,
        timeout: TimeInterval
    ) async throws -> PTPContainer {
        let header = try await readHeader(timeout: timeout)
        guard header.type == .response else {
            throw MTPError.unexpectedContainerType(expected: .response, actual: header.type)
        }
        guard header.transactionID == expectedTransactionID else {
            throw MTPError.invalidTransactionID(
                expected: expectedTransactionID,
                actual: header.transactionID
            )
        }
        return try await readResponseBody(
            header: header,
            operation: operation,
            timeout: timeout
        )
    }

    /// Reads the body of a response container whose header has already been
    /// consumed. Used when a device answers a command that normally has a data
    /// phase with a bare response instead (for example an empty
    /// GetObjectHandles on a virtual folder).
    func readResponseBody(
        header: PTPContainerHeader,
        operation: PTPOperationCode,
        timeout: TimeInterval
    ) async throws -> PTPContainer {
        guard header.type == .response else {
            throw MTPError.unexpectedContainerType(expected: .response, actual: header.type)
        }

        let bodyLength = Int(header.length) - 12
        let body = try await readExactly(bodyLength, timeout: timeout)
        let parameters = try Self.parseParameters(body)

        guard let code = PTPResponseCode(rawValue: header.code) else {
            throw MTPError.unexpectedResponseCode(operation: operation, rawCode: header.code)
        }
        guard code.isSuccess else {
            throw MTPError.response(operation: operation, code: code)
        }

        return PTPContainer(
            type: .response,
            code: header.code,
            transactionID: header.transactionID,
            parameters: parameters
        )
    }

    func readDataHeader(
        expectedTransactionID: UInt32,
        operation: PTPOperationCode,
        timeout: TimeInterval
    ) async throws -> PTPContainerHeader {
        let header = try await readHeader(timeout: timeout)
        guard header.type == .data else {
            throw MTPError.unexpectedContainerType(expected: .data, actual: header.type)
        }
        guard header.transactionID == expectedTransactionID else {
            throw MTPError.invalidTransactionID(
                expected: expectedTransactionID,
                actual: header.transactionID
            )
        }
        _ = operation
        return header
    }

    private static func parseParameters(_ data: Data) throws -> [UInt32] {
        guard !data.isEmpty else { return [] }
        guard data.count % 4 == 0 else {
            throw MTPError.invalidResponse("response parameter block is not 4-byte aligned")
        }
        var reader = ByteReader(data)
        var parameters = [UInt32]()
        parameters.reserveCapacity(data.count / 4)
        for _ in 0 ..< (data.count / 4) {
            parameters.append(try reader.readUInt32())
        }
        return parameters
    }
}
