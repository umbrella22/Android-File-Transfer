import Foundation
import XCTest
@testable import AndroidFileTransferKit

final class MTPDeviceSessionTests: XCTestCase {
    private func makeMock(
        extraRootHandles: [UInt32] = [],
        files: [MockMTPTransport.FileEntry]? = nil
    ) -> MockMTPTransport {
        let deviceInfo = PTPDeviceInfo(
            standardVersion: 100,
            vendorExtensionID: 6,
            mtpVersion: 100,
            mtpExtension: "microsoft.com: 1.0; android.com: 1.0",
            functionalMode: 0,
            operationsSupported: [
                PTPOperationCode.openSession.rawValue,
                PTPOperationCode.getDeviceInfo.rawValue,
                PTPOperationCode.getStorageIDs.rawValue,
            ],
            eventsSupported: [PTPEventCode.objectAdded.rawValue],
            devicePropertiesSupported: [],
            captureFormats: [],
            playbackFormats: [],
            manufacturer: "Mock",
            model: "Mock Phone",
            deviceVersion: "1.0",
            serialNumber: "MOCK-001"
        )

        let storageInfo = PTPStorageInfo(
            storageType: 4,
            filesystemType: 2,
            accessCapability: 0,
            maxCapacity: 128_000_000_000,
            freeSpaceInBytes: 64_000_000_000,
            freeSpaceInImages: 1000,
            storageDescription: "Internal shared storage",
            volumeLabel: ""
        )

        let dcim = PTPObjectInfo.folder(
            name: "DCIM",
            parent: 0xFFFF_FFFF,
            storageID: 1
        )
        let photo = PTPObjectInfo.file(
            name: "IMG_0001.JPG",
            parent: 0xFFFF_FFFF,
            storageID: 1,
            size: UInt64("hello MTP".utf8.count)
        )

        let defaultFiles: [MockMTPTransport.FileEntry] = [
            .init(handle: 0x101, info: dcim, contents: Data()),
            .init(handle: 0x102, info: photo, contents: Data("hello MTP".utf8)),
        ]

        return MockMTPTransport(
            deviceInfo: deviceInfo,
            storageID: 1,
            storageInfo: storageInfo,
            files: files ?? defaultFiles,
            extraRootHandles: extraRootHandles
        )
    }

    func testSessionMetadataAndListing() async throws {
        let session = MTPDeviceSession(transport: makeMock())
        let info = try await session.openSession()
        XCTAssertEqual(info.manufacturer, "Mock")
        XCTAssertEqual(info.model, "Mock Phone")
        XCTAssertEqual(info.serialNumber, "MOCK-001")

        let storages = try await session.storages()
        XCTAssertEqual(storages.count, 1)
        XCTAssertEqual(storages[0].id, 1)
        XCTAssertEqual(storages[0].info.storageDescription, "Internal shared storage")
        XCTAssertEqual(storages[0].info.freeSpaceInBytes, 64_000_000_000)

        let children = try await session.children(storageID: 1)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].handle, 0x101)
        XCTAssertTrue(children[0].info.isFolder)
        XCTAssertEqual(children[1].handle, 0x102)
        XCTAssertEqual(children[1].info.filename, "IMG_0001.JPG")

        await session.closeSession()
    }

    func testDownloadWritesFile() async throws {
        let session = MTPDeviceSession(transport: makeMock())
        _ = try await session.openSession()

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidFileTransfer-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        var progressValues: [Int64] = []
        try await session.download(handle: 0x102, to: destination) { value in
            progressValues.append(value)
        }

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(data, Data("hello MTP".utf8))
        XCTAssertEqual(progressValues.last, Int64("hello MTP".utf8.count))

        await session.closeSession()
    }

    func testMakeDirectoryUploadAndRename() async throws {
        let session = MTPDeviceSession(transport: makeMock())
        _ = try await session.openSession()

        let directoryHandle = try await session.makeDirectory(
            name: "New Folder",
            parent: 0xFFFF_FFFF,
            storageID: 1
        )
        XCTAssertGreaterThan(directoryHandle, 0)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidFileTransfer-\(UUID().uuidString).txt")
        let payload = Data("upload payload".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var uploadProgress: Int64 = 0
        let objectHandle = try await session.upload(
            fileURL: source,
            parent: 0xFFFF_FFFF,
            storageID: 1
        ) { written in
            uploadProgress = written
        }
        XCTAssertGreaterThan(objectHandle, 0)
        XCTAssertEqual(uploadProgress, Int64(payload.count))

        try await session.rename(handle: objectHandle, to: "renamed.txt")

        await session.closeSession()
    }

    func testConcurrentCallsAreSerialized() async throws {
        let session = MTPDeviceSession(transport: makeMock())
        _ = try await session.openSession()

        // Actor reentrancy would normally let these interleave between the
        // command and response awaits. The session's bus gate must serialize
        // them so the transaction IDs stay aligned.
        async let first = session.children(storageID: 1)
        async let second = session.children(storageID: 1)
        async let third = session.storageIDs()
        let (firstResult, secondResult, storageIDs) = try await (first, second, third)

        XCTAssertEqual(firstResult.count, 2)
        XCTAssertEqual(secondResult.count, 2)
        XCTAssertEqual(storageIDs, [1])

        await session.closeSession()
    }

    func testBareResponseForEmptyObjectHandles() async throws {
        let mock = makeMock()
        mock.bareObjectHandles = true
        let session = MTPDeviceSession(transport: mock)
        _ = try await session.openSession()

        // Android virtual folders sometimes answer GetObjectHandles with a
        // bare OK response instead of a zero-count data container.
        let handles = try await session.objectHandles(storageID: 1)
        XCTAssertTrue(handles.isEmpty)

        let children = try await session.children(storageID: 1)
        XCTAssertTrue(children.isEmpty)

        await session.closeSession()
    }

    func testInvalidObjectHandlesAreSkipped() async throws {
        let mock = makeMock(extraRootHandles: [0xDEAD_BEEF])
        let session = MTPDeviceSession(transport: mock)
        _ = try await session.openSession()

        // The extra handle is present in GetObjectHandles but GetObjectInfo
        // rejects it. The valid siblings must still be returned.
        let children = try await session.children(storageID: 1)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map(\.handle), [0x101, 0x102])

        await session.closeSession()
    }

    func testUnknownLengthDownloadDrainsBufferedChunks() async throws {
        let payload = Data(repeating: 0x5A, count: 100 * 1024 + 7)
        let largeInfo = PTPObjectInfo(
            storageID: 1,
            objectFormat: PTPObjectFormat.undefined.rawValue,
            protectionStatus: 0,
            compressedSize: PTPObjectInfo.unknownSize,
            thumbFormat: 0,
            thumbCompressedSize: 0,
            thumbPixWidth: 0,
            thumbPixHeight: 0,
            imagePixWidth: 0,
            imagePixHeight: 0,
            imageBitDepth: 0,
            parentObject: 0xFFFF_FFFF,
            associationType: 0,
            associationDesc: 0,
            sequenceNumber: 0,
            filename: "large.bin",
            captureDateRaw: "",
            modificationDateRaw: "",
            keywords: ""
        )
        let mock = makeMock(files: [
            .init(handle: 0x200, info: largeInfo, contents: payload),
        ])
        mock.useUnknownLengthForGetObject = true

        let session = MTPDeviceSession(transport: mock)
        _ = try await session.openSession()

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-unknown-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await session.download(handle: 0x200, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)

        await session.closeSession()
    }
}
