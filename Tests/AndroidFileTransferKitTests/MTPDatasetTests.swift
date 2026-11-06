import Foundation
import XCTest
@testable import AndroidFileTransferKit

final class MTPDatasetTests: XCTestCase {
    func testDeviceInfoDecode() throws {
        var writer = ByteWriter()
        writer.writeUInt16(100)                 // standard version
        writer.writeUInt32(6)                   // MTP vendor extension ID
        writer.writeUInt16(100)                 // MTP version
        try writer.writeString("microsoft.com: 1.0; android.com: 1.0")
        writer.writeUInt16(0)                   // functional mode
        writer.writeUInt16Array([0x1001, 0x1002])
        writer.writeUInt16Array([0x4002, 0x4003])
        writer.writeUInt16Array([0x5001])
        writer.writeUInt16Array([])
        writer.writeUInt16Array([])
        try writer.writeString("Google")
        try writer.writeString("Pixel 9")
        try writer.writeString("1.0")
        try writer.writeString("ABC123")

        let info = try PTPDeviceInfo.decode(Data(writer.bytes))
        XCTAssertEqual(info.standardVersion, 100)
        XCTAssertEqual(info.vendorExtensionID, 6)
        XCTAssertEqual(info.mtpVersion, 100)
        XCTAssertEqual(info.mtpExtension, "microsoft.com: 1.0; android.com: 1.0")
        XCTAssertEqual(info.operationsSupported, [0x1001, 0x1002])
        XCTAssertEqual(info.eventsSupported, [0x4002, 0x4003])
        XCTAssertEqual(info.devicePropertiesSupported, [0x5001])
        XCTAssertEqual(info.manufacturer, "Google")
        XCTAssertEqual(info.model, "Pixel 9")
        XCTAssertEqual(info.deviceVersion, "1.0")
        XCTAssertEqual(info.serialNumber, "ABC123")
    }

    func testStorageInfoDecode() throws {
        var writer = ByteWriter()
        writer.writeUInt16(4)                   // storage type: removable RAM
        writer.writeUInt16(2)                   // filesystem: hierarchical
        writer.writeUInt16(0)                   // access: read-write
        writer.writeUInt64(128_000_000_000)
        writer.writeUInt64(64_000_000_000)
        writer.writeUInt32(12_345)
        try writer.writeString("Internal shared storage")
        try writer.writeString("")

        let info = try PTPStorageInfo.decode(Data(writer.bytes))
        XCTAssertEqual(info.storageType, 4)
        XCTAssertEqual(info.filesystemType, 2)
        XCTAssertEqual(info.maxCapacity, 128_000_000_000)
        XCTAssertEqual(info.freeSpaceInBytes, 64_000_000_000)
        XCTAssertEqual(info.freeSpaceInImages, 12_345)
        XCTAssertEqual(info.storageDescription, "Internal shared storage")
        XCTAssertEqual(info.volumeLabel, "")
        XCTAssertFalse(info.isReadOnly)
    }

    func testObjectInfoDecode() throws {
        var writer = ByteWriter()
        writer.writeUInt32(0x0001_0001)         // storage ID
        writer.writeUInt16(PTPObjectFormat.undefined.rawValue)
        writer.writeUInt16(0)                   // protection
        writer.writeUInt32(1_234_567)           // size
        writer.writeUInt16(0)                   // thumb format
        writer.writeUInt32(0)                   // thumb size
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0xFFFF_FFFF)         // parent: root
        writer.writeUInt16(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        try writer.writeString("IMG_0001.JPG")
        try writer.writeString("20260101T120000")
        try writer.writeString("20260102T130000")
        try writer.writeString("")

        let info = try PTPObjectInfo.decode(Data(writer.bytes))
        XCTAssertEqual(info.storageID, 0x0001_0001)
        XCTAssertEqual(info.compressedSize, 1_234_567)
        XCTAssertEqual(info.parentObject, 0xFFFF_FFFF)
        XCTAssertEqual(info.filename, "IMG_0001.JPG")
        XCTAssertEqual(info.size, 1_234_567)
        XCTAssertFalse(info.isFolder)
        XCTAssertNotNil(info.modificationDate.date)
    }

    func testObjectInfoEncodeRoundTrip() throws {
        let original = PTPObjectInfo.file(
            name: "测试 📷.jpg",
            parent: 0xFFFF_FFFF,
            storageID: 0x0001_0001,
            size: 4_500_000_000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try PTPObjectInfo.decode(original.encoded())
        XCTAssertEqual(decoded.filename, original.filename)
        XCTAssertEqual(decoded.storageID, original.storageID)
        XCTAssertEqual(decoded.parentObject, original.parentObject)
        XCTAssertEqual(decoded.compressedSize, PTPObjectInfo.unknownSize)
        XCTAssertNil(decoded.size)
    }

    func testFolderInfo() throws {
        let folder = PTPObjectInfo.folder(
            name: "DCIM",
            parent: 0xFFFF_FFFF,
            storageID: 1
        )
        let decoded = try PTPObjectInfo.decode(folder.encoded())
        XCTAssertTrue(decoded.isFolder)
        XCTAssertEqual(decoded.filename, "DCIM")
    }
}
