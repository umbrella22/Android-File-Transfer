import Foundation
import XCTest
@testable import AndroidFileTransferKit

final class PTPCodecTests: XCTestCase {
    func testCommandContainerRoundTrip() throws {
        let container = PTPContainer(
            type: .command,
            code: PTPOperationCode.getObjectInfo.rawValue,
            transactionID: 42,
            parameters: [0x0001_0001]
        )
        let encoded = container.encoded()
        XCTAssertEqual(encoded.count, 16)

        let decoded = try PTPContainer.decode(encoded)
        XCTAssertEqual(decoded, container)
    }

    func testDataContainerRoundTrip() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let container = PTPContainer(
            type: .data,
            code: PTPOperationCode.getDeviceInfo.rawValue,
            transactionID: 7,
            payload: payload
        )
        let decoded = try PTPContainer.decode(container.encoded())
        XCTAssertEqual(decoded.type, .data)
        XCTAssertEqual(decoded.code, PTPOperationCode.getDeviceInfo.rawValue)
        XCTAssertEqual(decoded.transactionID, 7)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testContainerRejectsShortData() {
        XCTAssertThrowsError(try PTPContainer.decode(Data([0x01, 0x02])))
    }

    func testStringRoundTripASCII() throws {
        var writer = ByteWriter()
        try writer.writeString("DCIM")
        var reader = ByteReader(writer.bytes)
        XCTAssertEqual(try reader.readString(), "DCIM")
    }

    func testStringRoundTripUnicode() throws {
        for value in ["相机", "写真", "📷 Camera", "Ünïcode"] {
            var writer = ByteWriter()
            try writer.writeString(value)
            var reader = ByteReader(writer.bytes)
            XCTAssertEqual(try reader.readString(), value, "value: \(value)")
        }
    }

    func testEmptyStringEncoding() throws {
        var writer = ByteWriter()
        try writer.writeString("")
        XCTAssertEqual(writer.bytes, [0])

        var reader = ByteReader(writer.bytes)
        XCTAssertEqual(try reader.readString(), "")
    }
}
