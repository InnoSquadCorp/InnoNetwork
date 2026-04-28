import Foundation

/// Public WebSocket close code taxonomy that covers the full RFC 6455 range
/// plus application-defined custom codes.
///
/// This enum is the library's canonical close-code representation. It is used
/// by ``WebSocketTask/closeCode``, ``WebSocketManager/disconnect(_:closeCode:)``,
/// ``WebSocketManager/disconnectAll(closeCode:)`` and the internal
/// close-disposition classifier, so retry vs. terminal reasoning lives behind
/// typed cases rather than raw integers.
///
/// Why not use Foundation's `URLSessionWebSocketTask.CloseCode` directly?
/// Apple's enum omits `1012` (service restart) and `1013` (try again later),
/// which are retryable per RFC 6455. Library-defined codes in the 3000–4999
/// range also cannot be expressed there. `WebSocketCloseCode` preserves both.
///
/// Consumers can pattern-match on every case, including `.custom(UInt16)` for
/// application-level codes:
///
/// ```swift
/// switch task.closeCode {
/// case .serviceRestart, .tryAgainLater: retryWithBackoff()
/// case .custom(4001):                    handleAppSpecificClose()
/// default:                               break
/// }
/// ```
public enum WebSocketCloseCode: Sendable, Hashable {
    case normalClosure  // 1000
    case goingAway  // 1001
    case protocolError  // 1002
    case unsupportedData  // 1003
    case noStatusReceived  // 1005
    case abnormalClosure  // 1006
    case invalidFramePayloadData  // 1007
    case policyViolation  // 1008
    case messageTooBig  // 1009
    case mandatoryExtensionMissing  // 1010
    case internalServerError  // 1011
    case serviceRestart  // 1012
    case tryAgainLater  // 1013
    case badGateway  // 1014
    case tlsHandshakeFailure  // 1015
    /// RFC 6455 reserves the 3000-4999 block for libraries/applications.
    /// Any value outside of the standard 1000-1015 range falls here.
    case custom(UInt16)

    public var rawValue: UInt16 {
        switch self {
        case .normalClosure: return 1000
        case .goingAway: return 1001
        case .protocolError: return 1002
        case .unsupportedData: return 1003
        case .noStatusReceived: return 1005
        case .abnormalClosure: return 1006
        case .invalidFramePayloadData: return 1007
        case .policyViolation: return 1008
        case .messageTooBig: return 1009
        case .mandatoryExtensionMissing: return 1010
        case .internalServerError: return 1011
        case .serviceRestart: return 1012
        case .tryAgainLater: return 1013
        case .badGateway: return 1014
        case .tlsHandshakeFailure: return 1015
        case .custom(let value): return value
        }
    }

    public init(rawValue: UInt16) {
        switch rawValue {
        case 1000: self = .normalClosure
        case 1001: self = .goingAway
        case 1002: self = .protocolError
        case 1003: self = .unsupportedData
        case 1005: self = .noStatusReceived
        case 1006: self = .abnormalClosure
        case 1007: self = .invalidFramePayloadData
        case 1008: self = .policyViolation
        case 1009: self = .messageTooBig
        case 1010: self = .mandatoryExtensionMissing
        case 1011: self = .internalServerError
        case 1012: self = .serviceRestart
        case 1013: self = .tryAgainLater
        case 1014: self = .badGateway
        case 1015: self = .tlsHandshakeFailure
        default: self = .custom(rawValue)
        }
    }

    /// Bridges from Apple's `URLSessionWebSocketTask.CloseCode`. Used at the
    /// Foundation boundary (SessionDelegate) to convert incoming close codes
    /// into the library's canonical type. Not intended for consumer code —
    /// the public API already accepts/emits `WebSocketCloseCode` directly.
    package init(_ code: URLSessionWebSocketTask.CloseCode) {
        self.init(rawValue: UInt16(truncatingIfNeeded: code.rawValue))
    }

    /// Returns the matching `URLSessionWebSocketTask.CloseCode` when one
    /// exists; otherwise falls back to `.invalid`. Package-scoped because it
    /// is only useful at the Foundation boundary where URLSession demands its
    /// own enum.
    package var urlSessionCloseCode: URLSessionWebSocketTask.CloseCode {
        URLSessionWebSocketTask.CloseCode(rawValue: Int(rawValue)) ?? .invalid
    }
}
