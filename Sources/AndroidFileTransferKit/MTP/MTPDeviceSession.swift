import Foundation

/// Owns one MTP session and serializes every PTP transaction.
///
/// MTP is a single-session protocol: do not run two transactions against the
/// same device concurrently. The actor enforces that. A higher-level transfer
/// queue can still interleave work across jobs, but only one transaction is
/// in flight at a time.
public actor MTPDeviceSession {
    public struct Configuration: Sendable {
        public var commandTimeout: TimeInterval
        public var dataTimeout: TimeInterval
        public var transferChunkSize: Int
        public var debug: Bool

        public init(
            commandTimeout: TimeInterval = 10,
            dataTimeout: TimeInterval = 60,
            transferChunkSize: Int = 1 << 20,
            debug: Bool = false
        ) {
            self.commandTimeout = commandTimeout
            self.dataTimeout = dataTimeout
            self.transferChunkSize = max(64 * 1024, transferChunkSize)
            self.debug = debug
        }
    }

    private let transport: USBTransport
    private let reader: BufferedBulkReader
    private let configuration: Configuration

    private var transactionID: UInt32 = 0
    private var sessionID: UInt32 = 0
    private var sessionOpen = false
    private var closed = false

    // MTP requires one transaction in flight. Actor isolation alone is not
    // enough: every `await` inside a multi-phase transaction is a reentrancy
    // point, so a second call could interleave between SendObjectInfo and
    // SendObject. This FIFO gate is held across each complete operation.
    private var busBusy = false
    private var busWaiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: USBTransport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.reader = BufferedBulkReader(transport: transport)
        self.configuration = configuration
    }

    deinit {
        transport.close()
    }

    public var isSessionOpen: Bool { sessionOpen }

    // MARK: - Session lifecycle

    public func openSession() async throws -> PTPDeviceInfo {
        try await withBus { try await self._openSession() }
    }

    private func _openSession() async throws -> PTPDeviceInfo {
        guard !sessionOpen else { throw MTPError.alreadyOpen }
        guard !closed else { throw MTPError.notOpen }

        if !transport.isOpen {
            try await transport.open()
        }

        // A previous client may have crashed mid-transaction, leaving a
        // container in the bulk-in pipe. Clear it before OpenSession.
        await transport.drainStale()

        let sid = UInt32.random(in: 1 ... 0xFFFF_FFFE) | 1
        let openTransactionID: UInt32 = 0
        do {
            try await sendCommand(
                .openSession,
                parameters: [sid],
                transactionID: openTransactionID
            )
            _ = try await reader.readResponse(
                expectedTransactionID: openTransactionID,
                operation: .openSession,
                timeout: configuration.commandTimeout
            )
        } catch let error as MTPError {
            guard case let .response(operation, code) = error,
                  operation == .openSession,
                  code == .sessionAlreadyOpen
            else {
                throw error
            }

            // A previous client exited without closing its session. Android
            // accepts CloseSession without a transaction ID; close and retry.
            try await sendCommand(.closeSession, parameters: [], transactionID: 0)
            _ = try? await reader.readResponse(
                expectedTransactionID: 0,
                operation: .closeSession,
                timeout: configuration.commandTimeout
            )
            try await sendCommand(.openSession, parameters: [sid], transactionID: 0)
            _ = try await reader.readResponse(
                expectedTransactionID: 0,
                operation: .openSession,
                timeout: configuration.commandTimeout
            )
        }

        sessionID = sid
        transactionID = 1
        sessionOpen = true

        return try await _deviceInfo()
    }

    public func closeSession() async {
        await withBus { await self._closeSession() }
    }

    private func _closeSession() async {
        guard sessionOpen else {
            transport.close()
            closed = true
            return
        }

        let tid = nextTransactionID()
        try? await sendCommand(.closeSession, parameters: [], transactionID: tid)
        _ = try? await reader.readResponse(
            expectedTransactionID: tid,
            operation: .closeSession,
            timeout: configuration.commandTimeout
        )

        sessionOpen = false
        transactionID = 0
        sessionID = 0
        transport.close()
        closed = true
    }

    // MARK: - Device and storage metadata

    public func deviceInfo() async throws -> PTPDeviceInfo {
        try await withBus { try await self._deviceInfo() }
    }

    private func _deviceInfo() async throws -> PTPDeviceInfo {
        let data = try await executeData(.getDeviceInfo, parameters: [])
        return try PTPDeviceInfo.decode(data)
    }

    public func storageIDs() async throws -> [UInt32] {
        try await withBus { try await self._storageIDs() }
    }

    private func _storageIDs() async throws -> [UInt32] {
        let data = try await executeData(.getStorageIDs, parameters: [])
        if data.isEmpty { return [] }
        var reader = ByteReader(data)
        return try reader.readUInt32Array()
    }

    public func storageInfo(_ storageID: UInt32) async throws -> PTPStorageInfo {
        try await withBus { try await self._storageInfo(storageID) }
    }

    private func _storageInfo(_ storageID: UInt32) async throws -> PTPStorageInfo {
        let data = try await executeData(.getStorageInfo, parameters: [storageID])
        return try PTPStorageInfo.decode(data)
    }

    public func storages() async throws -> [(id: UInt32, info: PTPStorageInfo)] {
        try await withBus { try await self._storages() }
    }

    private func _storages() async throws -> [(id: UInt32, info: PTPStorageInfo)] {
        var result: [(UInt32, PTPStorageInfo)] = []
        for id in try await _storageIDs() {
            let info = try await _storageInfo(id)
            result.append((id, info))
        }
        return result
    }

    // MARK: - Objects

    public func objectHandles(
        storageID: UInt32,
        parent: UInt32 = 0xFFFF_FFFF,
        format: UInt16 = 0
    ) async throws -> [UInt32] {
        try await withBus {
            try await self._objectHandles(storageID: storageID, parent: parent, format: format)
        }
    }

    private func _objectHandles(
        storageID: UInt32,
        parent: UInt32,
        format: UInt16
    ) async throws -> [UInt32] {
        let data = try await executeData(
            .getObjectHandles,
            parameters: [storageID, UInt32(format), parent]
        )
        if data.isEmpty { return [] }
        var reader = ByteReader(data)
        return try reader.readUInt32Array()
    }

    public func objectInfo(_ handle: UInt32) async throws -> PTPObjectInfo {
        try await withBus { try await self._objectInfo(handle) }
    }

    private func _objectInfo(_ handle: UInt32) async throws -> PTPObjectInfo {
        let data = try await executeData(.getObjectInfo, parameters: [handle])
        return try PTPObjectInfo.decode(data)
    }

    /// Reads the 64-bit ObjectSize property (0xDC04). This is the reliable
    /// size source for objects larger than 4 GB, where ObjectInfo reports
    /// 0xFFFFFFFF and the GetObject data-container length may be truncated.
    public func objectSize(handle: UInt32) async throws -> UInt64 {
        try await withBus { try await self._objectSize(handle: handle) }
    }

    private func _objectSize(handle: UInt32) async throws -> UInt64 {
        let data = try await executeData(
            .getObjectPropValue,
            parameters: [handle, UInt32(PTPObjectProperty.objectSize.rawValue)]
        )
        var reader = ByteReader(data)
        if data.count >= 8 {
            return try reader.readUInt64()
        }
        if data.count >= 4 {
            return UInt64(try reader.readUInt32())
        }
        throw MTPError.invalidResponse("ObjectSize property returned \(data.count) bytes")
    }

    public func children(
        of parent: UInt32 = 0xFFFF_FFFF,
        storageID: UInt32
    ) async throws -> [(handle: UInt32, info: PTPObjectInfo)] {
        try await withBus { try await self._children(of: parent, storageID: storageID) }
    }

    private func _children(
        of parent: UInt32,
        storageID: UInt32
    ) async throws -> [(handle: UInt32, info: PTPObjectInfo)] {
        let handles = try await _objectHandles(storageID: storageID, parent: parent, format: 0)
        var result: [(UInt32, PTPObjectInfo)] = []
        result.reserveCapacity(handles.count)
        for handle in handles {
            do {
                let info = try await _objectInfo(handle)
                result.append((handle, info))
            } catch let error as MTPError {
                // Virtual or stale handles are common on Android's category
                // views. One bad handle should not hide the rest of a folder.
                if case let .response(_, code) = error,
                   code == .invalidObjectHandle || code == .specifiedObjectNotFound {
                    continue
                }
                throw error
            }
        }
        return result
    }

    public func makeDirectory(
        name: String,
        parent: UInt32,
        storageID: UInt32
    ) async throws -> UInt32 {
        try await withBus {
            try await self._makeDirectory(name: name, parent: parent, storageID: storageID)
        }
    }

    private func _makeDirectory(
        name: String,
        parent: UInt32,
        storageID: UInt32
    ) async throws -> UInt32 {
        let info = PTPObjectInfo.folder(name: name, parent: parent, storageID: storageID)
        let data = try info.encoded()
        let response = try await executeWithData(
            .sendObjectInfo,
            parameters: [storageID, parent],
            data: data
        )
        guard response.parameters.count >= 3 else {
            throw MTPError.invalidResponse("SendObjectInfo returned \(response.parameters.count) parameters")
        }
        return response.parameters[2]
    }

    public func delete(handle: UInt32) async throws {
        try await withBus { try await self._delete(handle: handle) }
    }

    private func _delete(handle: UInt32) async throws {
        _ = try await executeNoData(.deleteObject, parameters: [handle])
    }

    public func rename(handle: UInt32, to newName: String) async throws {
        try await withBus { try await self._rename(handle: handle, to: newName) }
    }

    private func _rename(handle: UInt32, to newName: String) async throws {
        var writer = ByteWriter()
        try writer.writeString(newName)
        _ = try await executeWithData(
            .setObjectPropValue,
            parameters: [handle, UInt32(PTPObjectProperty.objectFileName.rawValue)],
            data: Data(writer.bytes)
        )
    }

    public func move(handle: UInt32, to parent: UInt32, storageID: UInt32) async throws {
        try await withBus {
            try await self._move(handle: handle, to: parent, storageID: storageID)
        }
    }

    private func _move(handle: UInt32, to parent: UInt32, storageID: UInt32) async throws {
        _ = try await executeNoData(
            .moveObject,
            parameters: [handle, storageID, parent]
        )
    }

    @discardableResult
    public func copy(handle: UInt32, to parent: UInt32, storageID: UInt32) async throws -> UInt32 {
        try await withBus {
            try await self._copy(handle: handle, to: parent, storageID: storageID)
        }
    }

    private func _copy(handle: UInt32, to parent: UInt32, storageID: UInt32) async throws -> UInt32 {
        let response = try await executeNoData(
            .copyObject,
            parameters: [handle, storageID, parent]
        )
        guard let newHandle = response.parameters.first else {
            throw MTPError.invalidResponse("CopyObject returned no object handle")
        }
        return newHandle
    }

    // MARK: - Transfers

    public func download(
        handle: UInt32,
        to destination: URL,
        progress: ((Int64) -> Void)? = nil
    ) async throws {
        try await withBus {
            try await self._download(handle: handle, to: destination, progress: progress)
        }
    }

    private func _download(
        handle: UInt32,
        to destination: URL,
        progress: ((Int64) -> Void)? = nil
    ) async throws {
        let info = try await _objectInfo(handle)

        // ObjectInfo reports 0xFFFFFFFF for objects larger than 4 GB, and some
        // devices truncate the GetObject container length as well. Resolve the
        // size *before* starting GetObject: sending another command while the
        // device is in a data phase desynchronizes the session.
        var expectedSize: Int?
        if let size = info.size, size <= UInt64(Int.max) {
            expectedSize = Int(size)
        } else {
            do {
                let size = try await _objectSize(handle: handle)
                if size > 0, size <= UInt64(Int.max) {
                    expectedSize = Int(size)
                }
            } catch {
                // Fall back to unknown-length streaming below.
                if configuration.debug {
                    fputs("[MTP] ObjectSize query failed: \(error.localizedDescription)\n", stderr)
                }
            }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw MTPError.localFile("could not create \(destination.path)")
        }

        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }

        let tid = nextTransactionID()
        try await sendCommand(.getObject, parameters: [handle], transactionID: tid)
        let header = try await reader.readDataHeader(
            expectedTransactionID: tid,
            operation: .getObject,
            timeout: configuration.commandTimeout
        )

        if expectedSize == nil, header.length != 0xFFFF_FFFF {
            let declared = Int(header.length) - 12
            if declared > 0 {
                expectedSize = declared
            }
        }

        if configuration.debug, info.size == nil {
            let headerDescription = header.length == 0xFFFF_FFFF
                ? "sentinel"
                : String(Int(header.length) - 12)
            fputs(
                "[MTP] GetObject handle=\(handle) headerPayload=\(headerDescription) expected=\(String(describing: expectedSize))\n",
                stderr
            )
        }

        var written: Int64 = 0
        if let expected = expectedSize {
            var remaining = expected
            while remaining > 0 {
                let chunk = try await reader.readUpTo(
                    min(configuration.transferChunkSize, remaining),
                    timeout: configuration.dataTimeout
                )
                if chunk.isEmpty { break }
                try file.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress?(written)
                remaining -= chunk.count
            }
            if written < Int64(expected) {
                throw MTPError.invalidResponse(
                    "short GetObject data phase: expected \(expected), received \(written)"
                )
            }
        } else {
            while true {
                let (chunk, isShortTransfer) = try await reader.readChunk(
                    maxLength: configuration.transferChunkSize,
                    timeout: configuration.dataTimeout
                )
                if chunk.isEmpty { break }
                try file.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress?(written)
                if isShortTransfer { break }
            }
        }

        _ = try await reader.readResponse(
            expectedTransactionID: tid,
            operation: .getObject,
            timeout: configuration.commandTimeout
        )

        if let date = info.modificationDate.date {
            try? fileManager.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: destination.path
            )
        }
    }

    @discardableResult
    public func upload(
        fileURL: URL,
        parent: UInt32,
        storageID: UInt32,
        remoteName: String? = nil,
        progress: ((Int64) -> Void)? = nil
    ) async throws -> UInt32 {
        try await withBus {
            try await self._upload(
                fileURL: fileURL,
                parent: parent,
                storageID: storageID,
                remoteName: remoteName,
                progress: progress
            )
        }
    }

    @discardableResult
    private func _upload(
        fileURL: URL,
        parent: UInt32,
        storageID: UInt32,
        remoteName: String? = nil,
        progress: ((Int64) -> Void)? = nil
    ) async throws -> UInt32 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date ?? Date()
        let name = remoteName ?? fileURL.lastPathComponent

        let info = PTPObjectInfo.file(
            name: name,
            parent: parent,
            storageID: storageID,
            size: size,
            modificationDate: modificationDate
        )
        let infoData = try info.encoded()
        let infoResponse = try await executeWithData(
            .sendObjectInfo,
            parameters: [storageID, parent],
            data: infoData
        )
        guard infoResponse.parameters.count >= 3 else {
            throw MTPError.invalidResponse("SendObjectInfo returned \(infoResponse.parameters.count) parameters")
        }
        let handle = infoResponse.parameters[2]

        let tid = nextTransactionID()
        try await sendCommand(.sendObject, parameters: [], transactionID: tid)
        try await sendFileData(
            fileURL: fileURL,
            operation: .sendObject,
            transactionID: tid,
            totalSize: size,
            progress: progress
        )
        _ = try await reader.readResponse(
            expectedTransactionID: tid,
            operation: .sendObject,
            timeout: configuration.dataTimeout
        )
        return handle
    }

    /// Aborts the in-flight USB transfer. The session becomes desynchronized
    /// and must be closed; the app reconnects afterwards.
    public func abortCurrentOperation() {
        transport.abort()
        sessionOpen = false
    }

    public func resetDevice() async throws {
        try await withBus { try await self._resetDevice() }
    }

    private func _resetDevice() async throws {
        _ = try await executeNoData(.resetDevice, parameters: [])
        sessionOpen = false
    }

    // MARK: - Transactions

    private func acquireBus() async {
        if !busBusy {
            busBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            busWaiters.append(continuation)
        }
        // The previous owner resumed us after handing ownership over; busBusy
        // remains true until we call releaseBus().
    }

    private func releaseBus() {
        if let next = busWaiters.first {
            busWaiters.removeFirst()
            next.resume()
        } else {
            busBusy = false
        }
    }

    private func withBus<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquireBus()
        do {
            let result = try await body()
            releaseBus()
            return result
        } catch {
            releaseBus()
            throw error
        }
    }

    private func requireSession() throws {
        guard sessionOpen else { throw MTPError.notOpen }
    }

    private func nextTransactionID() -> UInt32 {
        let id = transactionID
        transactionID &+= 1
        if transactionID == 0 {
            transactionID = 1
        }
        return id
    }

    private func sendCommand(
        _ operation: PTPOperationCode,
        parameters: [UInt32],
        transactionID: UInt32
    ) async throws {
        let container = PTPContainer(
            type: .command,
            code: operation.rawValue,
            transactionID: transactionID,
            parameters: parameters
        )
        try await transport.write(container.encoded(), timeout: configuration.commandTimeout)
    }

    private func executeNoData(
        _ operation: PTPOperationCode,
        parameters: [UInt32]
    ) async throws -> PTPContainer {
        try requireSession()
        let tid = nextTransactionID()
        try await sendCommand(operation, parameters: parameters, transactionID: tid)
        return try await reader.readResponse(
            expectedTransactionID: tid,
            operation: operation,
            timeout: configuration.commandTimeout
        )
    }

    private func executeData(
        _ operation: PTPOperationCode,
        parameters: [UInt32]
    ) async throws -> Data {
        try requireSession()
        let tid = nextTransactionID()
        try await sendCommand(operation, parameters: parameters, transactionID: tid)

        let header = try await reader.readHeader(timeout: configuration.commandTimeout)
        guard header.transactionID == tid else {
            throw MTPError.invalidTransactionID(expected: tid, actual: header.transactionID)
        }

        // Some devices answer an empty array or a virtual folder with a bare
        // response instead of a zero-length data container.
        if header.type == .response {
            _ = try await reader.readResponseBody(
                header: header,
                operation: operation,
                timeout: configuration.commandTimeout
            )
            return Data()
        }

        guard header.type == .data else {
            throw MTPError.unexpectedContainerType(expected: .data, actual: header.type)
        }
        guard header.length != 0xFFFF_FFFF else {
            throw MTPError.invalidResponse("unbounded data phase for \(operation.description)")
        }
        let payloadLength = Int(header.length) - 12
        let payload = try await reader.readExactly(
            payloadLength,
            timeout: configuration.dataTimeout
        )
        _ = try await reader.readResponse(
            expectedTransactionID: tid,
            operation: operation,
            timeout: configuration.commandTimeout
        )
        return payload
    }

    private func executeWithData(
        _ operation: PTPOperationCode,
        parameters: [UInt32],
        data: Data
    ) async throws -> PTPContainer {
        try requireSession()
        let tid = nextTransactionID()
        try await sendCommand(operation, parameters: parameters, transactionID: tid)
        try await sendData(
            operation: operation,
            transactionID: tid,
            data: data,
            progress: nil
        )
        return try await reader.readResponse(
            expectedTransactionID: tid,
            operation: operation,
            timeout: configuration.commandTimeout
        )
    }

    // MARK: - Data phase writes

    private func dataHeader(
        operation: PTPOperationCode,
        transactionID: UInt32,
        payloadLength: UInt64
    ) -> Data {
        var writer = ByteWriter()
        let totalLength = payloadLength + 12
        let encodedLength = totalLength > UInt64(UInt32.max)
            ? UInt32.max
            : UInt32(totalLength)
        writer.writeUInt32(encodedLength)
        writer.writeUInt16(PTPContainerType.data.rawValue)
        writer.writeUInt16(operation.rawValue)
        writer.writeUInt32(transactionID)
        return Data(writer.bytes)
    }

    private func sendData(
        operation: PTPOperationCode,
        transactionID: UInt32,
        data: Data,
        progress: ((Int64) -> Void)?
    ) async throws {
        let header = dataHeader(
            operation: operation,
            transactionID: transactionID,
            payloadLength: UInt64(data.count)
        )
        let maxPacket = max(1, transport.bulkOutMaxPacketSize)
        let firstPayloadSize = max(0, maxPacket - header.count)
        let chunkSize = max(maxPacket, (configuration.transferChunkSize / maxPacket) * maxPacket)

        // If the whole payload fits in the first, packet-aligned write, send
        // it in one go. A short final packet is itself the end-of-data signal;
        // an exactly full packet needs a zero-length terminator.
        if data.count <= firstPayloadSize {
            var buffer = header
            buffer.append(data)
            try await transport.write(buffer, timeout: configuration.dataTimeout)
            progress?(Int64(data.count))
            try await finishDataPhase(lastTransferSize: buffer.count)
            return
        }

        var buffer = header
        buffer.append(data.prefix(firstPayloadSize))
        try await transport.write(buffer, timeout: configuration.dataTimeout)
        var sent = Int64(firstPayloadSize)
        progress?(sent)
        var lastTransferSize = buffer.count

        var offset = firstPayloadSize
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset ..< end)
            try await transport.write(chunk, timeout: configuration.dataTimeout)
            sent += Int64(chunk.count)
            progress?(sent)
            lastTransferSize = chunk.count
            offset = end
        }

        try await finishDataPhase(lastTransferSize: lastTransferSize)
    }

    private func sendFileData(
        fileURL: URL,
        operation: PTPOperationCode,
        transactionID: UInt32,
        totalSize: UInt64,
        progress: ((Int64) -> Void)?
    ) async throws {
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }

        let header = dataHeader(
            operation: operation,
            transactionID: transactionID,
            payloadLength: totalSize
        )
        let maxPacket = max(1, transport.bulkOutMaxPacketSize)
        let firstPayloadSize = max(0, maxPacket - header.count)
        let chunkSize = max(maxPacket, (configuration.transferChunkSize / maxPacket) * maxPacket)

        var sent: Int64 = 0
        var lastTransferSize = 0
        var firstWrite = true

        while true {
            // The first write must be a full USB packet. A short packet in
            // the middle of a multi-packet MTP data phase tells the device
            // that the object is already complete.
            let requested = firstWrite ? firstPayloadSize : chunkSize
            let chunk = try file.read(upToCount: requested) ?? Data()
            if chunk.isEmpty { break }

            if firstWrite {
                var buffer = header
                buffer.append(chunk)
                try await transport.write(buffer, timeout: configuration.dataTimeout)
                lastTransferSize = buffer.count
                firstWrite = false
            } else {
                try await transport.write(chunk, timeout: configuration.dataTimeout)
                lastTransferSize = chunk.count
            }

            sent += Int64(chunk.count)
            progress?(sent)
        }

        if firstWrite {
            // Empty file: send just the header. It is short by definition.
            try await transport.write(header, timeout: configuration.dataTimeout)
            lastTransferSize = header.count
        }

        try await finishDataPhase(lastTransferSize: lastTransferSize)
    }

    private func finishDataPhase(lastTransferSize: Int) async throws {
        // A bulk data phase that ends exactly on a max-packet boundary needs a
        // zero-length packet to tell the device the data is complete.
        guard lastTransferSize > 0,
              lastTransferSize % transport.bulkOutMaxPacketSize == 0
        else {
            return
        }
        try await transport.write(Data(), timeout: configuration.commandTimeout)
    }
}
