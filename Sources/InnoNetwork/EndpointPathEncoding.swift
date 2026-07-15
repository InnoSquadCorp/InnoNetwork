import Foundation

/// Utilities for safely embedding dynamic values into endpoint path segments.
public enum EndpointPathEncoding {
    /// Percent-encodes a dynamic value for use as a single URL path segment.
    ///
    /// Unlike endpoint literal paths, dynamic placeholder values are treated
    /// as raw segment values. Slashes and percent signs are encoded so a user
    /// identifier such as `a/b` cannot accidentally change the path hierarchy.
    ///
    /// The value must have a lossless string representation so path
    /// placeholders do not accidentally accept arbitrary debug descriptions.
    /// Use primitive identifiers (`Int`, `String`, `Bool`, etc.), `UUID`, or
    /// raw-value enums whose raw value is losslessly string-convertible.
    public static func percentEncodedSegment<T>(_ value: T) -> String
    where T: LosslessStringConvertible & Sendable {
        percentEncodedSegment(String(value))
    }

    /// Percent-encodes a dynamic UUID for use as a single URL path segment.
    public static func percentEncodedSegment(_ value: UUID) -> String {
        percentEncodedSegment(value.uuidString)
    }

    /// Percent-encodes a dynamic raw-value enum for use as a single URL path
    /// segment.
    public static func percentEncodedSegment<T>(_ value: T) -> String
    where T: RawRepresentable & Sendable, T.RawValue: LosslessStringConvertible & Sendable {
        percentEncodedSegment(value.rawValue)
    }

    /// Percent-encodes a dynamic string for use as a single URL path segment.
    public static func percentEncodedSegment(_ value: String) -> String {
        // Dot segments have special path-normalization semantics even though
        // `.` is otherwise an RFC 3986 unreserved character. Encode them so
        // the value can never be mistaken for a literal traversal segment;
        // the shared admission gate then rejects the final URL before IO.
        if value == "." { return "%2E" }
        if value == ".." { return "%2E%2E" }
        return percentEncode(value, preservingPercentEscapes: false, allowsSlash: false)
    }

    package static func percentEncodedPathLiteral(_ path: String) throws -> String {
        guard !path.contains("?"), !path.contains("#") else {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "Endpoint path must not contain query or fragment components. Use parameters/queryEncoder for query values."
                ))
        }
        try NetworkURLAdmission.validatePercentEncodedPath(path)
        return try percentEncodePathLiteral(path)
    }

    private static func percentEncodePathLiteral(_ value: String) throws -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard let scalar = value[index].unicodeScalars.first else {
                throw invalidPercentEscape(in: value)
            }
            if scalar.value == Self.percent {
                let first = value.index(after: index)
                guard first < value.endIndex else {
                    throw invalidPercentEscape(in: value)
                }
                let second = value.index(after: first)
                guard second < value.endIndex,
                    let firstScalar = value[first].unicodeScalars.first,
                    let secondScalar = value[second].unicodeScalars.first,
                    isHexDigit(firstScalar),
                    isHexDigit(secondScalar)
                else {
                    throw invalidPercentEscape(in: value)
                }
                result.append("%")
                result.append(value[first])
                result.append(value[second])
                index = value.index(after: second)
                continue
            }

            result.append(percentEncode(String(value[index]), preservingPercentEscapes: true, allowsSlash: true))
            index = value.index(after: index)
        }
        return result
    }

    private static func percentEncode(
        _ value: String,
        preservingPercentEscapes: Bool,
        allowsSlash: Bool
    ) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if preservingPercentEscapes, scalar.value == Self.percent {
                result.append("%")
            } else if isAllowedPathScalar(scalar, allowsSlash: allowsSlash) {
                result.append(String(scalar))
            } else {
                for byte in String(scalar).utf8 {
                    result.append(percentEncoded(byte))
                }
            }
        }
        return result
    }

    private static func invalidPercentEscape(in path: String) -> NetworkError {
        NetworkError.configuration(
            reason: .invalidRequest(
                "Endpoint path must be a valid percent-encoded URL path. Invalid percent escape found in '\(path)'."))
    }

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    private static func percentEncoded(_ byte: UInt8) -> String {
        let high = Int(byte >> 4)
        let low = Int(byte & 0x0F)
        return "%\(hexDigits[high])\(hexDigits[low])"
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }

    private static func isAllowedPathScalar(_ scalar: Unicode.Scalar, allowsSlash: Bool) -> Bool {
        switch scalar.value {
        case 65...90, 97...122, 48...57:
            return true
        case 45, 46, 95, 126:
            return true
        case 33, 36, 38, 39, 40, 41, 42, 43, 44, 59, 61, 58, 64:
            return true
        case slash where allowsSlash && slash == Self.slash:
            return true
        default:
            return false
        }
    }

    private static let percent: UInt32 = 37
    private static let slash: UInt32 = 47
}

package enum EndpointPathBuilder {
    package static func makeURL(
        baseURL: URL,
        endpointPath: String,
        allowsInsecureHTTP: Bool = false
    ) throws -> URL {
        try NetworkURLAdmission.validate(baseURL, policy: .http(allowsInsecure: allowsInsecureHTTP))
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.configuration(reason: .invalidBaseURL("Base URL is malformed."))
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let childPath = try EndpointPathEncoding.percentEncodedPathLiteral(endpointPath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch (basePath.isEmpty, childPath.isEmpty) {
        case (true, true):
            components.percentEncodedPath = "/"
        case (true, false):
            components.percentEncodedPath = "/" + childPath
        case (false, true):
            components.percentEncodedPath = "/" + basePath
        case (false, false):
            components.percentEncodedPath = "/" + basePath + "/" + childPath
        }

        guard let url = components.url else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Endpoint path must be a valid percent-encoded URL path."))
        }
        try NetworkURLAdmission.validate(url, policy: .http(allowsInsecure: allowsInsecureHTTP))
        return url
    }
}
