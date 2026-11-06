import Foundation

public enum MTPError: Error, LocalizedError {
    case transport(USBTransportError)
    case notOpen
    case alreadyOpen
    case response(operation: PTPOperationCode, code: PTPResponseCode)
    case unexpectedResponseCode(operation: PTPOperationCode, rawCode: UInt16)
    case unexpectedContainerType(expected: PTPContainerType, actual: PTPContainerType)
    case invalidTransactionID(expected: UInt32, actual: UInt32)
    case unexpectedData(operation: PTPOperationCode)
    case unexpectedEndOfStream
    case unsupported(String)
    case localFile(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .transport(error):
            return error.localizedDescription
        case .notOpen:
            return "MTP session is not open"
        case .alreadyOpen:
            return "MTP session is already open"
        case let .response(operation, code):
            return "\(operation.description) failed: \(code.description) (0x\(String(code.rawValue, radix: 16)))"
        case let .unexpectedResponseCode(operation, rawCode):
            return "\(operation.description) returned unknown response code 0x\(String(rawCode, radix: 16))"
        case let .unexpectedContainerType(expected, actual):
            return "Expected \(expected) container, got \(actual)"
        case let .invalidTransactionID(expected, actual):
            return "Transaction ID mismatch: expected \(expected), got \(actual)"
        case let .unexpectedData(operation):
            return "\(operation.description) returned an unexpected data phase"
        case .unexpectedEndOfStream:
            return "The device ended the transfer without a response container"
        case let .unsupported(message):
            return "Unsupported operation: \(message)"
        case let .localFile(message):
            return "Local file error: \(message)"
        case let .invalidResponse(message):
            return "Invalid MTP response: \(message)"
        }
    }
}

extension MTPError {
    static func map(_ error: Error) -> MTPError {
        if let error = error as? MTPError { return error }
        if let error = error as? USBTransportError { return .transport(error) }
        return .invalidResponse(String(describing: error))
    }
}
