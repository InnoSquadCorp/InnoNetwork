import Foundation

/// Utilities for safely embedding dynamic values into endpoint path segments.
public enum EndpointPathEncoding {
    /// Percent-encodes a dynamic value for use as a single URL path segment.
    ///
    /// Unlike endpoint literal paths, dynamic placeholder values are treated
    /// as raw segment values. Slashes and percent signs are encoded so a user
    /// identifier such as `a/b` cannot accidentally change the path hierarchy.
    ///
    /// The value is rendered via `String(describing:)`, which matches what
    /// Swift's string interpolation produces. Pass primitive identifiers
    /// (`Int`, `UUID`, raw-value enums) or values whose `description` is the
    /// intended segment text. Optional values trigger an `assertionFailure`
    /// in DEBUG builds because `String(describing:)` would silently render
    /// them as `Optional(...)` / `nil` and ship a malformed URL; in RELEASE
    /// builds the unwrapped description is used so transient logs/metrics
    /// remain inspectable rather than crashing in production.
    public static func percentEncodedSegment<T>(_ value: T) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            assertionFailure(
                "EndpointPathEncoding.percentEncodedSegment received an Optional value, which would render as 'Optional(...)' or 'nil'. Unwrap the value before passing it to a path placeholder."
            )
            if let child = mirror.children.first {
                return percentEncodedSegment(child.value)
            }
            return percentEncodedSegment("nil")
        }
        return percentEncodedSegment(String(describing: value))
    }

    /// Percent-encodes a dynamic string for use as a single URL path segment.
    public static func percentEncodedSegment(_ value: String) -> String {
        percentEncode(value, preservingPercentEscapes: false, allowsSlash: false)
    }

    package static func percentEncodedPathLiteral(_ path: String) throws -> String {
        guard !path.contains("?"), !path.contains("#") else {
            throw NetworkError.invalidRequestConfiguration(
                "Endpoint path must not contain query or fragment components. Use parameters/queryEncoder for query values."
            )
        }
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
        NetworkError.invalidRequestConfiguration(
            "Endpoint path must be a valid percent-encoded URL path. Invalid percent escape found in '\(path)'."
        )
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
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidBaseURL(baseURL.absoluteString)
        }

        if let scheme = components.scheme?.lowercased(), scheme == "http", !allowsInsecureHTTP {
            throw NetworkError.invalidBaseURL(
                "Plain HTTP base URL is rejected by default. Pass allowsInsecureHTTP: true on NetworkConfiguration to opt in."
            )
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
            throw NetworkError.invalidRequestConfiguration(
                "Endpoint path must be a valid percent-encoded URL path."
            )
        }
        return url
    }
}
