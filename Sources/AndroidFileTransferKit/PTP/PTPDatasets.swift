import Foundation

// MARK: - Device info

public struct PTPDeviceInfo: Sendable, Equatable {
    public let standardVersion: UInt16
    public let vendorExtensionID: UInt32
    public let mtpVersion: UInt16
    public let mtpExtension: String
    public let functionalMode: UInt16
    public let operationsSupported: [UInt16]
    public let eventsSupported: [UInt16]
    public let devicePropertiesSupported: [UInt16]
    public let captureFormats: [UInt16]
    public let playbackFormats: [UInt16]
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    public init(
        standardVersion: UInt16,
        vendorExtensionID: UInt32,
        mtpVersion: UInt16,
        mtpExtension: String,
        functionalMode: UInt16,
        operationsSupported: [UInt16],
        eventsSupported: [UInt16],
        devicePropertiesSupported: [UInt16],
        captureFormats: [UInt16],
        playbackFormats: [UInt16],
        manufacturer: String,
        model: String,
        deviceVersion: String,
        serialNumber: String
    ) {
        self.standardVersion = standardVersion
        self.vendorExtensionID = vendorExtensionID
        self.mtpVersion = mtpVersion
        self.mtpExtension = mtpExtension
        self.functionalMode = functionalMode
        self.operationsSupported = operationsSupported
        self.eventsSupported = eventsSupported
        self.devicePropertiesSupported = devicePropertiesSupported
        self.captureFormats = captureFormats
        self.playbackFormats = playbackFormats
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        self.serialNumber = serialNumber
    }

    public static func decode(_ data: Data) throws -> PTPDeviceInfo {
        var reader = ByteReader(data)
        return PTPDeviceInfo(
            standardVersion: try reader.readUInt16(),
            vendorExtensionID: try reader.readUInt32(),
            mtpVersion: try reader.readUInt16(),
            mtpExtension: try reader.readString(),
            functionalMode: try reader.readUInt16(),
            operationsSupported: try reader.readUInt16Array(),
            eventsSupported: try reader.readUInt16Array(),
            devicePropertiesSupported: try reader.readUInt16Array(),
            captureFormats: try reader.readUInt16Array(),
            playbackFormats: try reader.readUInt16Array(),
            manufacturer: try reader.readString(),
            model: try reader.readString(),
            deviceVersion: try reader.readString(),
            serialNumber: try reader.readString()
        )
    }
}

// MARK: - Storage info

public struct PTPStorageInfo: Sendable, Equatable {
    public let storageType: UInt16
    public let filesystemType: UInt16
    public let accessCapability: UInt16
    public let maxCapacity: UInt64
    public let freeSpaceInBytes: UInt64
    public let freeSpaceInImages: UInt32
    public let storageDescription: String
    public let volumeLabel: String

    public init(
        storageType: UInt16,
        filesystemType: UInt16,
        accessCapability: UInt16,
        maxCapacity: UInt64,
        freeSpaceInBytes: UInt64,
        freeSpaceInImages: UInt32,
        storageDescription: String,
        volumeLabel: String
    ) {
        self.storageType = storageType
        self.filesystemType = filesystemType
        self.accessCapability = accessCapability
        self.maxCapacity = maxCapacity
        self.freeSpaceInBytes = freeSpaceInBytes
        self.freeSpaceInImages = freeSpaceInImages
        self.storageDescription = storageDescription
        self.volumeLabel = volumeLabel
    }

    public static func decode(_ data: Data) throws -> PTPStorageInfo {
        var reader = ByteReader(data)
        return PTPStorageInfo(
            storageType: try reader.readUInt16(),
            filesystemType: try reader.readUInt16(),
            accessCapability: try reader.readUInt16(),
            maxCapacity: try reader.readUInt64(),
            freeSpaceInBytes: try reader.readUInt64(),
            freeSpaceInImages: try reader.readUInt32(),
            storageDescription: try reader.readString(),
            volumeLabel: try reader.readString()
        )
    }

    public var isReadOnly: Bool {
        accessCapability == PTPAccessCapability.readOnly.rawValue
            || accessCapability == PTPAccessCapability.readOnlyWithObjectDeletion.rawValue
    }
}

// MARK: - Object info

public struct PTPObjectInfo: Sendable, Equatable {
    public static let unknownSize: UInt32 = 0xFFFF_FFFF

    public let storageID: UInt32
    public let objectFormat: UInt16
    public let protectionStatus: UInt16
    public let compressedSize: UInt32
    public let thumbFormat: UInt16
    public let thumbCompressedSize: UInt32
    public let thumbPixWidth: UInt32
    public let thumbPixHeight: UInt32
    public let imagePixWidth: UInt32
    public let imagePixHeight: UInt32
    public let imageBitDepth: UInt32
    public let parentObject: UInt32
    public let associationType: UInt16
    public let associationDesc: UInt32
    public let sequenceNumber: UInt32
    public let filename: String
    public let captureDateRaw: String
    public let modificationDateRaw: String
    public let keywords: String

    public init(
        storageID: UInt32,
        objectFormat: UInt16,
        protectionStatus: UInt16,
        compressedSize: UInt32,
        thumbFormat: UInt16,
        thumbCompressedSize: UInt32,
        thumbPixWidth: UInt32,
        thumbPixHeight: UInt32,
        imagePixWidth: UInt32,
        imagePixHeight: UInt32,
        imageBitDepth: UInt32,
        parentObject: UInt32,
        associationType: UInt16,
        associationDesc: UInt32,
        sequenceNumber: UInt32,
        filename: String,
        captureDateRaw: String,
        modificationDateRaw: String,
        keywords: String
    ) {
        self.storageID = storageID
        self.objectFormat = objectFormat
        self.protectionStatus = protectionStatus
        self.compressedSize = compressedSize
        self.thumbFormat = thumbFormat
        self.thumbCompressedSize = thumbCompressedSize
        self.thumbPixWidth = thumbPixWidth
        self.thumbPixHeight = thumbPixHeight
        self.imagePixWidth = imagePixWidth
        self.imagePixHeight = imagePixHeight
        self.imageBitDepth = imageBitDepth
        self.parentObject = parentObject
        self.associationType = associationType
        self.associationDesc = associationDesc
        self.sequenceNumber = sequenceNumber
        self.filename = filename
        self.captureDateRaw = captureDateRaw
        self.modificationDateRaw = modificationDateRaw
        self.keywords = keywords
    }

    public static func decode(_ data: Data) throws -> PTPObjectInfo {
        var reader = ByteReader(data)
        return PTPObjectInfo(
            storageID: try reader.readUInt32(),
            objectFormat: try reader.readUInt16(),
            protectionStatus: try reader.readUInt16(),
            compressedSize: try reader.readUInt32(),
            thumbFormat: try reader.readUInt16(),
            thumbCompressedSize: try reader.readUInt32(),
            thumbPixWidth: try reader.readUInt32(),
            thumbPixHeight: try reader.readUInt32(),
            imagePixWidth: try reader.readUInt32(),
            imagePixHeight: try reader.readUInt32(),
            imageBitDepth: try reader.readUInt32(),
            parentObject: try reader.readUInt32(),
            associationType: try reader.readUInt16(),
            associationDesc: try reader.readUInt32(),
            sequenceNumber: try reader.readUInt32(),
            filename: try reader.readString(),
            captureDateRaw: try reader.readString(),
            modificationDateRaw: try reader.readString(),
            keywords: try reader.readString()
        )
    }

    public var isFolder: Bool {
        objectFormat == PTPObjectFormat.association.rawValue
    }

    /// Returns nil when the device reports the 0xFFFFFFFF sentinel for files
    /// larger than 4 GB. The real size may still be obtainable through the
    /// Android ObjectSize property or a streaming read.
    public var size: UInt64? {
        compressedSize == Self.unknownSize ? nil : UInt64(compressedSize)
    }

    public var modificationDate: PTPDate {
        PTPDate(raw: modificationDateRaw)
    }

    public var creationDate: PTPDate {
        PTPDate(raw: captureDateRaw)
    }

    public static func folder(
        name: String,
        parent: UInt32,
        storageID: UInt32,
        date: Date = Date()
    ) -> PTPObjectInfo {
        PTPObjectInfo(
            storageID: storageID,
            objectFormat: PTPObjectFormat.association.rawValue,
            protectionStatus: 0,
            compressedSize: 0,
            thumbFormat: 0,
            thumbCompressedSize: 0,
            thumbPixWidth: 0,
            thumbPixHeight: 0,
            imagePixWidth: 0,
            imagePixHeight: 0,
            imageBitDepth: 0,
            parentObject: parent,
            associationType: 0,
            associationDesc: 0,
            sequenceNumber: 0,
            filename: name,
            captureDateRaw: PTPDateFormatter.string(from: date),
            modificationDateRaw: PTPDateFormatter.string(from: date),
            keywords: ""
        )
    }

    public static func file(
        name: String,
        parent: UInt32,
        storageID: UInt32,
        size: UInt64,
        modificationDate: Date = Date()
    ) -> PTPObjectInfo {
        let reportedSize = size > UInt64(unknownSize) ? unknownSize : UInt32(size)
        return PTPObjectInfo(
            storageID: storageID,
            objectFormat: PTPObjectFormat.undefined.rawValue,
            protectionStatus: 0,
            compressedSize: reportedSize,
            thumbFormat: 0,
            thumbCompressedSize: 0,
            thumbPixWidth: 0,
            thumbPixHeight: 0,
            imagePixWidth: 0,
            imagePixHeight: 0,
            imageBitDepth: 0,
            parentObject: parent,
            associationType: 0,
            associationDesc: 0,
            sequenceNumber: 0,
            filename: name,
            captureDateRaw: PTPDateFormatter.string(from: modificationDate),
            modificationDateRaw: PTPDateFormatter.string(from: modificationDate),
            keywords: ""
        )
    }

    /// Encodes the PTP ObjectInfo dataset used by SendObjectInfo.
    public func encoded() throws -> Data {
        var writer = ByteWriter()
        writer.writeUInt32(storageID)
        writer.writeUInt16(objectFormat)
        writer.writeUInt16(protectionStatus)
        writer.writeUInt32(compressedSize)
        writer.writeUInt16(thumbFormat)
        writer.writeUInt32(thumbCompressedSize)
        writer.writeUInt32(thumbPixWidth)
        writer.writeUInt32(thumbPixHeight)
        writer.writeUInt32(imagePixWidth)
        writer.writeUInt32(imagePixHeight)
        writer.writeUInt32(imageBitDepth)
        writer.writeUInt32(parentObject)
        writer.writeUInt16(associationType)
        writer.writeUInt32(associationDesc)
        writer.writeUInt32(sequenceNumber)
        try writer.writeString(filename)
        try writer.writeString(captureDateRaw)
        try writer.writeString(modificationDateRaw)
        try writer.writeString(keywords)
        return Data(writer.bytes)
    }
}

public enum PTPDateFormatter {
    public static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Dates

public struct PTPDate: Sendable, Equatable {
    public let raw: String
    public let date: Date?

    public init(raw: String) {
        self.raw = raw
        self.date = PTPDate.parse(raw)
    }

    private static func parse(_ raw: String) -> Date? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Samsung devices append dots; some devices append Z.
        while value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasSuffix("Z") {
            value.removeLast()
        }

        let formats = [
            "yyyyMMdd'T'HHmmss",
            "yyyyMMdd'T'HHmmssZ",
            "yyyyMMdd'T'HHmmssZZZZZ",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

// MARK: - Events

public struct PTPEvent: Sendable, Equatable {
    public let code: UInt16
    public let transactionID: UInt32
    public let parameters: [UInt32]

    public init(code: UInt16, transactionID: UInt32, parameters: [UInt32]) {
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public var eventCode: PTPEventCode? {
        PTPEventCode(rawValue: code)
    }

    public static func decode(_ container: PTPContainer) -> PTPEvent {
        PTPEvent(
            code: container.code,
            transactionID: container.transactionID,
            parameters: container.parameters
        )
    }
}
