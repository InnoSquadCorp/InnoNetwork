//
//  NetworkError.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation


/// Specific timeout that produced a ``NetworkError/timeout(reason:)``.
///
/// Distinguishing between request, resource, and connection timeouts lets
/// the UI surface targeted retry copy ("the request is taking longer than
/// expected" vs. "we couldn't reach the server") instead of a generic
/// transport failure.
public enum TimeoutReason: Sendable, Equatable {
    /// `URLError.timedOut` produced by the request timeoutInterval.
    case requestTimeout
    /// `URLError.timedOut` produced by the resource timeoutInterval (for
    /// long-running uploads or background sessions).
    case resourceTimeout
    /// Connection establishment timed out (for example, a captive portal
    /// blocking the TCP handshake).
    case connectionTimeout
}


public enum NetworkError: Error, Sendable {
    case invalidBaseURL(String)
    /// Indicates an invalid request configuration
    case invalidRequestConfiguration(String)
    /// Indicates a response failed to map to a JSON structure.
    case jsonMapping(Response)
    /// Indicates a response failed with an invalid HTTP status code.
    case statusCode(Response)
    /// Indicates a response failed to map to a Decodable object.
    case objectMapping(SendableUnderlyingError, Response)

    case nonHTTPResponse(URLResponse)

    case underlying(SendableUnderlyingError, Response?)
    case trustEvaluationFailed(TrustFailureReason)

    case undefined
    case cancelled
    /// The request did not complete within its configured timeout window.
    case timeout(reason: TimeoutReason)
}


extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let string):
            return "Invalid base URL: \(string)"
        case .invalidRequestConfiguration(let message):
            return "Invalid request configuration: \(message)"
        case .jsonMapping:
            return "Failed to map data to JSON."
        case .objectMapping(let error, _):
            return "Failed to map data to a Decodable object: \(error.message)"
        case .statusCode:
            return "Status code didn't fall within the given range."
        case .underlying(let error, _):
            return error.message
        case .nonHTTPResponse:
            return "Failed to convert nonHTTPResponse"
        case .trustEvaluationFailed(let reason):
            switch reason {
            case .unsupportedAuthenticationMethod(let method):
                return "Unsupported authentication method: \(method)"
            case .missingServerTrust:
                return "Missing server trust."
            case .systemTrustEvaluationFailed:
                return "System trust evaluation failed."
            case .hostNotPinned(let host):
                return "No pin configured for host: \(host)"
            case .publicKeyExtractionFailed:
                return "Failed to extract public key from certificate chain."
            case .pinMismatch(let host):
                return "Public key pin mismatch for host: \(host)"
            case .custom(let message):
                return message
            }
        case .undefined:
            return "Undefined Error"
        case .cancelled:
            return "Request was cancelled"
        case .timeout(let reason):
            switch reason {
            case .requestTimeout:
                return "The request timed out before the server responded."
            case .resourceTimeout:
                return "The resource transfer timed out."
            case .connectionTimeout:
                return "The connection to the server timed out."
            }
        }
    }
}

public extension NetworkError {
    /// Depending on error type, returns a `Response` object.
    var response: Response? {
        switch self {
        case .invalidBaseURL: return nil
        case .invalidRequestConfiguration: return nil
        case .jsonMapping(let response): return response
        case .objectMapping(_, let response): return response
        case .statusCode(let response): return response
        case .underlying(_, let response): return response
        case .nonHTTPResponse: return nil
        case .trustEvaluationFailed: return nil
        case .undefined: return nil
        case .cancelled: return nil
        case .timeout: return nil
        }
    }

    /// Depending on error type, returns an underlying `Error`.
    internal var underlyingError: SendableUnderlyingError? {
        switch self {
        case .invalidBaseURL: return nil
        case .invalidRequestConfiguration: return nil
        case .jsonMapping: return nil
        case .objectMapping(let error, _): return error
        case .statusCode: return nil
        case .underlying(let error, _): return error
        case .nonHTTPResponse: return nil
        case .trustEvaluationFailed: return nil
        case .undefined: return nil
        case .cancelled: return nil
        case .timeout: return nil
        }
    }
}

// MARK: - Error User Info

extension NetworkError: CustomNSError {
    public static var errorDomain: String {
        "com.innosquad.innonetwork"
    }

    public var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [:]
        userInfo[NSLocalizedDescriptionKey] = errorDescription ?? "Network error"
        if let underlyingError {
            userInfo[NSUnderlyingErrorKey] = underlyingError
        }
        return userInfo
    }
}

// MARK: - Cancellation Check

extension NetworkError {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    static func mapTransportError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }

        if let trustEvaluationError = error as? TrustEvaluationError {
            switch trustEvaluationError {
            case .failed(let reason, _):
                return .trustEvaluationFailed(reason)
            }
        }

        if isCancellation(error) {
            return .cancelled
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout(reason: .requestTimeout)
            case .cannotConnectToHost:
                return .timeout(reason: .connectionTimeout)
            default:
                break
            }
        }

        return .underlying(SendableUnderlyingError(error), nil)
    }
}
