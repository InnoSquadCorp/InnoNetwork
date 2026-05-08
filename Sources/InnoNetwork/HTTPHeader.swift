//
//  HTTPHeader.swift
//  Network
//
//  Created by Chang Woo Son on 6/21/24.
//

import Foundation

// MARK: - HTTPHeader

/// A representation of a single HTTP header's name / value pair.
public struct HTTPHeader: Hashable, Sendable {
    /// Name of the header.
    public let name: String

    /// Value of the header.
    public let value: String

    /// Creates an instance from the given `name` and `value`.
    ///
    /// - Parameters:
    ///   - name:  The name of the header.
    ///   - value: The value of the header.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension HTTPHeader: CustomStringConvertible {
    public var description: String {
        "\(name): \(value)"
    }
}

extension HTTPHeader {
    /// Returns an `Accept` header.
    ///
    /// - Parameter value: The `Accept` value.
    /// - Returns:         The header.
    public static func accept(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept", value: value)
    }

    /// Returns an `Accept-Charset` header.
    ///
    /// - Parameter value: The `Accept-Charset` value.
    /// - Returns:         The header.
    public static func acceptCharset(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Charset", value: value)
    }

    /// Returns an `Accept-Language` header.
    ///
    /// For a default value generated from the system's preferred languages,
    /// use ``HTTPHeader/defaultAcceptLanguage``.
    ///
    /// - Parameter value: The `Accept-Language` value.
    ///
    /// - Returns:         The header.
    public static func acceptLanguage(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Language", value: value)
    }

    /// Returns an `Accept-Encoding` header.
    ///
    /// For a default value covering the encodings supported by the current
    /// platform, use ``HTTPHeader/defaultAcceptEncoding``.
    ///
    /// - Parameter value: The `Accept-Encoding` value.
    ///
    /// - Returns:         The header
    public static func acceptEncoding(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Encoding", value: value)
    }

    /// Returns a `Basic` `Authorization` header using the `username` and `password` provided.
    ///
    /// Credentials are normalized to Unicode NFC and encoded as UTF-8 before
    /// Base64 encoding. RFC 7617 defines the `charset=UTF-8` parameter only
    /// on `WWW-Authenticate` challenges; `Authorization` credentials remain a
    /// single token68 value, so this helper does not append auth parameters.
    ///
    /// - Parameters:
    ///   - username: The username of the header.
    ///   - password: The password of the header.
    ///
    /// - Returns:    The header.
    public static func authorization(username: String, password: String) -> HTTPHeader {
        let userPass = "\(username):\(password)" as NSString
        let normalizedUserPass = userPass.precomposedStringWithCanonicalMapping
        let credential = Data(normalizedUserPass.utf8).base64EncodedString()

        return authorization("Basic \(credential)")
    }

    /// Returns a `Bearer` `Authorization` header using the `bearerToken` provided.
    ///
    /// - Parameter bearerToken: The bearer token.
    ///
    /// - Returns:               The header.
    public static func authorization(bearerToken: String) -> HTTPHeader {
        authorization("Bearer \(bearerToken)")
    }

    /// Returns an `Authorization` header.
    ///
    /// Convenience constructors are provided for the two most common
    /// schemes: ``authorization(username:password:)`` for Basic auth and
    /// ``authorization(bearerToken:)`` for Bearer tokens. Reach for this
    /// raw constructor only when neither helper fits.
    ///
    /// - Parameter value: The `Authorization` value.
    ///
    /// - Returns:         The header.
    public static func authorization(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Authorization", value: value)
    }

    /// Returns a `Content-Disposition` header.
    ///
    /// - Parameter value: The `Content-Disposition` value.
    ///
    /// - Returns:         The header.
    public static func contentDisposition(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Disposition", value: value)
    }

    /// Returns a `Content-Encoding` header.
    ///
    /// - Parameter value: The `Content-Encoding`.
    ///
    /// - Returns:         The header.
    public static func contentEncoding(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Encoding", value: value)
    }

    /// Returns a `Content-Type` header.
    ///
    /// `APIDefinition.contentType` and `MultipartAPIDefinition` set the
    /// `Content-Type` automatically when an encoded body is present, so manual
    /// configuration is rarely needed for the standard request encoding paths.
    ///
    /// - Parameter value: The `Content-Type` value.
    ///
    /// - Returns:         The header.
    public static func contentType(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Type", value: value)
    }

    /// Returns a `User-Agent` header.
    ///
    /// - Parameter value: The `User-Agent` value.
    ///
    /// - Returns:         The header.
    public static func userAgent(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "User-Agent", value: value)
    }

    /// Returns a `Sec-WebSocket-Protocol` header.
    ///
    /// - Parameter value: The `Sec-WebSocket-Protocol` value.
    /// - Returns:         The header.
    public static func websocketProtocol(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Sec-WebSocket-Protocol", value: value)
    }
}
