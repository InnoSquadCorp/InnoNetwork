//
//  NetworkError.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation


public enum NetworkError: Error {
    case invalidBaseURL(String)
    /// Indicates a response failed to map to a JSON structure.
    case jsonMapping(Response)
    /// Indicates a response failed with an invalid HTTP status code.
    case statusCode(Response)
    /// Indicates a response failed to map to a Decodable object.
    case objectMapping(Swift.Error, Response)

    case nonHTTPResponse(URLResponse)

    case underlying(Swift.Error, Response?)

    case undefined
    case cancelled
}


extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let string):
            return "Invalid base URL: \(string)"
        case .jsonMapping:
            return "Failed to map data to JSON."
        case .objectMapping:
            return "Failed to map data to a Decodable object."
        case .statusCode:
            return "Status code didn fall within the given range."
        case .underlying(let error, _):
            return error.localizedDescription
        case .nonHTTPResponse:
            return "Failed to convert nonHTTPResponse"
        case .undefined:
            return "Undefined Error"
        case .cancelled:
            return "Request was cancelled"
        }
    }
}

public extension NetworkError {
    /// Depending on error type, returns a `Response` object.
    var response: Response? {
        switch self {
        case .invalidBaseURL: return nil
        case .jsonMapping(let response): return response
        case .objectMapping(_, let response): return response
        case .statusCode(let response): return response
        case .underlying(_, let response): return response
        case .nonHTTPResponse: return nil
        case .undefined: return nil
        case .cancelled: return nil
        }
    }

    /// Depending on error type, returns an underlying `Error`.
    internal var underlyingError: Swift.Error? {
        switch self {
        case .invalidBaseURL: return nil
        case .jsonMapping: return nil
        case .objectMapping(let error, _): return error
        case .statusCode: return nil
        case .underlying(let error, _): return error
        case .nonHTTPResponse: return nil
        case .undefined: return nil
        case .cancelled: return nil
        }
    }
}

// MARK: - Error User Info

extension NetworkError: CustomNSError {
    public var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [:]
        userInfo[NSLocalizedDescriptionKey] = errorDescription
        userInfo[NSUnderlyingErrorKey] = underlyingError
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
}
