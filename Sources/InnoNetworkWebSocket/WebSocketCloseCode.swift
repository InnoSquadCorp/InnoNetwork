import Foundation


/// Package-internal WebSocket close code taxonomy that covers the full RFC 6455
/// range plus application-defined custom codes. Used by the close-disposition
/// classifier so retry/terminal decisions can switch over type-safe cases
/// instead of raw integers. Public API continues to expose
/// `URLSessionWebSocketTask.CloseCode` to preserve the existing contract.
package enum WebSocketCloseCode: Sendable, Hashable {
    case normalClosure              // 1000
    case goingAway                  // 1001
    case protocolError              // 1002
    case unsupportedData            // 1003
    case noStatusReceived           // 1005
    case abnormalClosure            // 1006
    case invalidFramePayloadData    // 1007
    case policyViolation            // 1008
    case messageTooBig              // 1009
    case mandatoryExtensionMissing  // 1010
    case internalServerError        // 1011
    case serviceRestart             // 1012
    case tryAgainLater              // 1013
    case badGateway                 // 1014
    case tlsHandshakeFailure        // 1015
    /// RFC 6455 reserves the 3000-4999 block for libraries/applications.
    /// Any value outside of the standard 1000-1015 range falls here.
    case custom(UInt16)

    package var rawValue: UInt16 {
        switch self {
        case .normalClosure:             return 1000
        case .goingAway:                 return 1001
        case .protocolError:             return 1002
        case .unsupportedData:           return 1003
        case .noStatusReceived:          return 1005
        case .abnormalClosure:           return 1006
        case .invalidFramePayloadData:   return 1007
        case .policyViolation:           return 1008
        case .messageTooBig:             return 1009
        case .mandatoryExtensionMissing: return 1010
        case .internalServerError:       return 1011
        case .serviceRestart:            return 1012
        case .tryAgainLater:             return 1013
        case .badGateway:                return 1014
        case .tlsHandshakeFailure:       return 1015
        case .custom(let value):         return value
        }
    }

    package init(rawValue: UInt16) {
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
        default:   self = .custom(rawValue)
        }
    }

    package init(_ code: URLSessionWebSocketTask.CloseCode) {
        self.init(rawValue: UInt16(truncatingIfNeeded: code.rawValue))
    }

    /// Returns the matching `URLSessionWebSocketTask.CloseCode` when one
    /// exists; otherwise falls back to `.invalid` (used for associated-value
    /// propagation into public API surfaces that demand an Apple enum).
    package var urlSessionCloseCode: URLSessionWebSocketTask.CloseCode {
        URLSessionWebSocketTask.CloseCode(rawValue: Int(rawValue)) ?? .invalid
    }
}
