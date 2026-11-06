import Foundation

// MARK: - Container types

public enum PTPContainerType: UInt16, Sendable, CustomStringConvertible {
    case command = 1
    case data = 2
    case response = 3
    case event = 4

    public var description: String {
        switch self {
        case .command: return "command"
        case .data: return "data"
        case .response: return "response"
        case .event: return "event"
        }
    }
}

// MARK: - Operation codes

public enum PTPOperationCode: UInt16, Sendable, CustomStringConvertible {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case formatStore = 0x100F
    case resetDevice = 0x1010
    case getDevicePropDesc = 0x1014
    case getDevicePropValue = 0x1015
    case setDevicePropValue = 0x1016
    case resetDevicePropValue = 0x1017
    case moveObject = 0x1019
    case copyObject = 0x101A
    case getPartialObject = 0x101B

    // MTP extensions
    case getObjectPropsSupported = 0x9801
    case getObjectPropDesc = 0x9802
    case getObjectPropValue = 0x9803
    case setObjectPropValue = 0x9804
    case getObjectPropList = 0x9805
    case setObjectPropList = 0x9806
    case sendObjectPropList = 0x9808
    case getObjectReferences = 0x9810
    case setObjectReferences = 0x9811

    // Android extensions
    case androidGetPartialObject64 = 0x95C1
    case androidSendPartialObject = 0x95C2
    case androidTruncateObject = 0x95C3
    case androidBeginEditObject = 0x95C4
    case androidEndEditObject = 0x95C5

    public var description: String {
        switch self {
        case .getDeviceInfo: return "GetDeviceInfo"
        case .openSession: return "OpenSession"
        case .closeSession: return "CloseSession"
        case .getStorageIDs: return "GetStorageIDs"
        case .getStorageInfo: return "GetStorageInfo"
        case .getNumObjects: return "GetNumObjects"
        case .getObjectHandles: return "GetObjectHandles"
        case .getObjectInfo: return "GetObjectInfo"
        case .getObject: return "GetObject"
        case .getThumb: return "GetThumb"
        case .deleteObject: return "DeleteObject"
        case .sendObjectInfo: return "SendObjectInfo"
        case .sendObject: return "SendObject"
        case .formatStore: return "FormatStore"
        case .resetDevice: return "ResetDevice"
        case .getDevicePropDesc: return "GetDevicePropDesc"
        case .getDevicePropValue: return "GetDevicePropValue"
        case .setDevicePropValue: return "SetDevicePropValue"
        case .resetDevicePropValue: return "ResetDevicePropValue"
        case .moveObject: return "MoveObject"
        case .copyObject: return "CopyObject"
        case .getPartialObject: return "GetPartialObject"
        case .getObjectPropsSupported: return "GetObjectPropsSupported"
        case .getObjectPropDesc: return "GetObjectPropDesc"
        case .getObjectPropValue: return "GetObjectPropValue"
        case .setObjectPropValue: return "SetObjectPropValue"
        case .getObjectPropList: return "GetObjectPropList"
        case .setObjectPropList: return "SetObjectPropList"
        case .sendObjectPropList: return "SendObjectPropList"
        case .getObjectReferences: return "GetObjectReferences"
        case .setObjectReferences: return "SetObjectReferences"
        case .androidGetPartialObject64: return "ANDROID_GetPartialObject64"
        case .androidSendPartialObject: return "ANDROID_SendPartialObject"
        case .androidTruncateObject: return "ANDROID_TruncateObject"
        case .androidBeginEditObject: return "ANDROID_BeginEditObject"
        case .androidEndEditObject: return "ANDROID_EndEditObject"
        }
    }
}

// MARK: - Response codes

public enum PTPResponseCode: UInt16, Error, Sendable, CustomStringConvertible {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case invalidTransactionID = 0x2004
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer = 0x2007
    case invalidStorageID = 0x2008
    case invalidObjectHandle = 0x2009
    case devicePropNotSupported = 0x200A
    case invalidObjectFormatCode = 0x200B
    case storeFull = 0x200C
    case objectWriteProtected = 0x200D
    case storeReadOnly = 0x200E
    case accessDenied = 0x200F
    case noThumbnailPresent = 0x2010
    case selfTestFailed = 0x2011
    case partialDeletion = 0x2012
    case storeNotAvailable = 0x2013
    case specificationByFormatUnsupported = 0x2014
    case noValidObjectInfo = 0x2015
    case invalidCodeFormat = 0x2016
    case unknownVendorCode = 0x2017
    case captureAlreadyTerminated = 0x2018
    case deviceBusy = 0x2019
    case invalidParentObject = 0x201A
    case invalidDevicePropFormat = 0x201B
    case invalidDevicePropValue = 0x201C
    case invalidParameter = 0x201D
    case sessionAlreadyOpen = 0x201E
    case transactionCancelled = 0x201F
    case destinationUnsupported = 0x2020
    case specifiedObjectNotFound = 0x2021
    case invalidObjectPropCode = 0x2022

    public var isSuccess: Bool { self == .ok }

    public var description: String {
        switch self {
        case .ok: return "OK"
        case .generalError: return "GeneralError"
        case .sessionNotOpen: return "SessionNotOpen"
        case .invalidTransactionID: return "InvalidTransactionID"
        case .operationNotSupported: return "OperationNotSupported"
        case .parameterNotSupported: return "ParameterNotSupported"
        case .incompleteTransfer: return "IncompleteTransfer"
        case .invalidStorageID: return "InvalidStorageID"
        case .invalidObjectHandle: return "InvalidObjectHandle"
        case .devicePropNotSupported: return "DevicePropNotSupported"
        case .invalidObjectFormatCode: return "InvalidObjectFormatCode"
        case .storeFull: return "StoreFull"
        case .objectWriteProtected: return "ObjectWriteProtected"
        case .storeReadOnly: return "StoreReadOnly"
        case .accessDenied: return "AccessDenied"
        case .noThumbnailPresent: return "NoThumbnailPresent"
        case .selfTestFailed: return "SelfTestFailed"
        case .partialDeletion: return "PartialDeletion"
        case .storeNotAvailable: return "StoreNotAvailable"
        case .specificationByFormatUnsupported: return "SpecificationByFormatUnsupported"
        case .noValidObjectInfo: return "NoValidObjectInfo"
        case .invalidCodeFormat: return "InvalidCodeFormat"
        case .unknownVendorCode: return "UnknownVendorCode"
        case .captureAlreadyTerminated: return "CaptureAlreadyTerminated"
        case .deviceBusy: return "DeviceBusy"
        case .invalidParentObject: return "InvalidParentObject"
        case .invalidDevicePropFormat: return "InvalidDevicePropFormat"
        case .invalidDevicePropValue: return "InvalidDevicePropValue"
        case .invalidParameter: return "InvalidParameter"
        case .sessionAlreadyOpen: return "SessionAlreadyOpen"
        case .transactionCancelled: return "TransactionCancelled"
        case .destinationUnsupported: return "DestinationUnsupported"
        case .specifiedObjectNotFound: return "SpecifiedObjectNotFound"
        case .invalidObjectPropCode: return "InvalidObjectPropCode"
        }
    }
}

// MARK: - Event codes

public enum PTPEventCode: UInt16, Sendable, CustomStringConvertible {
    case objectAdded = 0x4002
    case objectRemoved = 0x4003
    case storeAdded = 0x4004
    case storeRemoved = 0x4005
    case devicePropChanged = 0x4006
    case objectInfoChanged = 0x4007
    case deviceInfoChanged = 0x4008
    case requestObjectTransfer = 0x4009
    case storeFull = 0x400A
    case deviceReset = 0x400B
    case storageInfoChanged = 0x400C
    case captureComplete = 0x400D
    case unreportedStatus = 0x400E

    public var description: String {
        switch self {
        case .objectAdded: return "ObjectAdded"
        case .objectRemoved: return "ObjectRemoved"
        case .storeAdded: return "StoreAdded"
        case .storeRemoved: return "StoreRemoved"
        case .devicePropChanged: return "DevicePropChanged"
        case .objectInfoChanged: return "ObjectInfoChanged"
        case .deviceInfoChanged: return "DeviceInfoChanged"
        case .requestObjectTransfer: return "RequestObjectTransfer"
        case .storeFull: return "StoreFull"
        case .deviceReset: return "DeviceReset"
        case .storageInfoChanged: return "StorageInfoChanged"
        case .captureComplete: return "CaptureComplete"
        case .unreportedStatus: return "UnreportedStatus"
        }
    }
}

// MARK: - Object formats

public enum PTPObjectFormat: UInt16, Sendable {
    case undefined = 0x3000
    case association = 0x3001

    public var isFolder: Bool { self == .association }
}

// MARK: - Object properties

public enum PTPObjectProperty: UInt16, Sendable, CustomStringConvertible {
    case storageID = 0xDC01
    case objectFormat = 0xDC02
    case protectionStatus = 0xDC03
    case objectSize = 0xDC04
    case associationType = 0xDC05
    case associationDesc = 0xDC06
    case objectFileName = 0xDC07
    case dateCreated = 0xDC08
    case dateModified = 0xDC09
    case keywords = 0xDC0A
    case parentObject = 0xDC0B
    case hidden = 0xDC0C
    case systemObject = 0xDC0D

    public var description: String {
        switch self {
        case .storageID: return "StorageID"
        case .objectFormat: return "ObjectFormat"
        case .protectionStatus: return "ProtectionStatus"
        case .objectSize: return "ObjectSize"
        case .associationType: return "AssociationType"
        case .associationDesc: return "AssociationDesc"
        case .objectFileName: return "ObjectFileName"
        case .dateCreated: return "DateCreated"
        case .dateModified: return "DateModified"
        case .keywords: return "Keywords"
        case .parentObject: return "ParentObject"
        case .hidden: return "Hidden"
        case .systemObject: return "SystemObject"
        }
    }
}

// MARK: - Storage constants

public enum PTPStorageType: UInt16, Sendable {
    case undefined = 0
    case fixedROM = 1
    case removableROM = 2
    case fixedRAM = 3
    case removableRAM = 4
}

public enum PTPFilesystemType: UInt16, Sendable {
    case undefined = 0
    case genericFlat = 1
    case genericHierarchical = 2
    case dcf = 3
}

public enum PTPAccessCapability: UInt16, Sendable {
    case readWrite = 0
    case readOnly = 1
    case readOnlyWithObjectDeletion = 2
}
