//
//  HTTPMethod.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

/// An HTTP request method represented by an RFC 9110 `token`.
///
/// Standard methods are available as static constants. Custom extension
/// methods remain case-sensitive and can be created with ``init(rawValue:)``:
///
/// ```swift
/// let purge = HTTPMethod(rawValue: "PURGE")
/// ```
public struct HTTPMethod: RawRepresentable, Sendable, Hashable {
    /// The case-sensitive method token sent on the wire.
    public let rawValue: String

    /// Creates a method when `rawValue` is a nonempty RFC 9110 `token`.
    ///
    /// Empty values, controls, whitespace, non-ASCII characters, and HTTP
    /// separator characters are rejected instead of reaching `URLRequest`.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.allSatisfy(Self.isTokenCharacter) else {
            return nil
        }
        self.rawValue = rawValue
    }

    private init(standard rawValue: String) {
        self.rawValue = rawValue
    }

    public static let get = HTTPMethod(standard: "GET")
    public static let head = HTTPMethod(standard: "HEAD")
    public static let post = HTTPMethod(standard: "POST")
    public static let put = HTTPMethod(standard: "PUT")
    public static let patch = HTTPMethod(standard: "PATCH")
    public static let delete = HTTPMethod(standard: "DELETE")
    public static let connect = HTTPMethod(standard: "CONNECT")
    public static let options = HTTPMethod(standard: "OPTIONS")
    public static let trace = HTTPMethod(standard: "TRACE")

    package var defaultsToQueryTransport: Bool {
        self == .get || self == .head
    }

    package var forbidsRequestBody: Bool {
        self == .get || self == .head || self == .trace
    }

    private static func isTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39,  // DIGIT
            0x41...0x5A,  // ALPHA
            0x61...0x7A,
            0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
            0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            true
        default:
            false
        }
    }
}
