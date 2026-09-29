import Foundation

/// Package-wide admission checks for absolute network URLs.
///
/// Companion targets use this gate before handing a URL to Foundation so
/// every transport applies the same origin and path-traversal policy without
/// widening the public API surface.
package enum NetworkURLAdmission {
    package enum Policy: Sendable {
        case http(allowsInsecure: Bool)
        case webSocket(allowsInsecure: Bool)
    }

    /// Validates an absolute URL and returns it unchanged when admitted.
    @discardableResult
    package static func validate(_ url: URL, policy: Policy) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            throw invalidURL("Network URL must be absolute and include a scheme.")
        }

        let secureScheme: String
        let insecureScheme: String
        let insecureAllowed: Bool
        switch policy {
        case .http(let allowsInsecure):
            secureScheme = "https"
            insecureScheme = "http"
            insecureAllowed = allowsInsecure
        case .webSocket(let allowsInsecure):
            secureScheme = "wss"
            insecureScheme = "ws"
            insecureAllowed = allowsInsecure
        }

        guard scheme == secureScheme || scheme == insecureScheme else {
            throw invalidURL("Network URL uses an unsupported scheme.")
        }
        guard scheme != insecureScheme || insecureAllowed else {
            throw invalidURL("Insecure network URLs are rejected unless the matching configuration opt-in is enabled.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw invalidURL("Network URL must include a host.")
        }
        guard isStructurallyValidHost(host) else {
            throw invalidURL("Network URL contains an ambiguous or malformed host.")
        }
        guard components.user == nil, components.password == nil else {
            throw invalidURL(
                "Network URL must not contain userinfo. Use an interceptor or request header for credentials."
            )
        }
        guard components.fragment == nil else {
            throw invalidURL("Network URL must not contain a fragment.")
        }
        try validatePercentEncodedPath(components.percentEncodedPath)
        return url
    }

    /// Validates the final URL carried by a request immediately before a
    /// transport boundary. Request interceptors and authentication policies
    /// can replace the complete `URLRequest`, so validating only the URL that
    /// `RequestBuilder` originally produced is insufficient.
    @discardableResult
    package static func validate(_ request: URLRequest, policy: Policy) throws -> URLRequest {
        guard let url = request.url else {
            throw invalidURL("Network requests must include an absolute URL.")
        }
        try validate(url, policy: policy)
        return request
    }

    /// Rejects RFC 3986 dot segments, including recursively percent-encoded
    /// spellings such as `%2e`, `%2E%2E`, and `%252e%252e`.
    package static func validatePercentEncodedPath(_ path: String) throws {
        guard !containsDotSegment(path) else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Network URL paths must not contain '.' or '..' segments.")
            )
        }
    }

    package static func containsDotSegment(_ path: String) -> Bool {
        // A dot segment needs either a literal dot or a percent escape.
        // Ordinary paths need no replacement strings or percent-decoding buffer.
        guard path.utf8.contains(0x2E) || path.utf8.contains(0x25) else { return false }
        return DotSegmentScan(path).containsDotSegment
    }

    /// A suffix stack reduces every structural escape, including escapes formed
    /// by earlier reductions. Each input byte is pushed once and every reduction
    /// removes two bytes: O(n) work/storage regardless of percent nesting depth.
    /// Keep this structural-only policy separate from full URL percent decoding.
    struct DotSegmentScan {
        private(set) var containsDotSegment = false
        #if DEBUG
        private(set) var scannedByteCount = 0
        #endif

        init(_ path: String) {
            var output: [UInt8] = []
            output.reserveCapacity(path.utf8.count)
            for byte in path.utf8 {
                recordScanWork(1)
                output.append(byte)
                while output.count >= 3 {
                    recordScanWork(3)
                    let start = output.count - 3
                    guard output[start] == 0x25,
                        let high = NetworkURLAdmission.hexValue(output[start + 1]),
                        let low = NetworkURLAdmission.hexValue(output[start + 2])
                    else { break }
                    let decoded = (high << 4) | low
                    guard decoded == 0x25 || decoded == 0x2E || decoded == 0x2F || decoded == 0x5C else { break }
                    output.removeLast(3)
                    output.append(decoded)
                }
            }
            // Once isolated, a dot segment survives every later reduction:
            // its literal dots and separators cannot be consumed by an escape.
            var dots = 0
            for byte in output {
                recordScanWork(1)
                if byte == 0x2F || byte == 0x5C {
                    if dots == 1 || dots == 2 {
                        containsDotSegment = true
                        return
                    }
                    dots = 0
                } else {
                    dots = byte == 0x2E ? min(dots + 1, 3) : 3
                }
            }
            containsDotSegment = dots == 1 || dots == 2
        }

        @inline(__always)
        private mutating func recordScanWork(_ count: Int) {
            #if DEBUG
            scannedByteCount += count
            #endif
        }
    }

    /// `URLComponents` decodes percent escapes in `host`, including escapes
    /// for authority delimiters such as `%40` (`@`) and `%2F` (`/`). Reject
    /// those parser-ambiguous spellings before a different networking parser
    /// can interpret the same URL with a different authority boundary.
    ///
    /// Colons and percent signs remain valid inside a bracketed IPv6 literal
    /// so IPv6 addresses and RFC 6874 zone identifiers continue to work.
    private static func isStructurallyValidHost(_ host: String) -> Bool {
        let scalars = host.unicodeScalars
        let isBracketedIPv6 = host.first == "[" && host.last == "]"
        let lastIndex = scalars.index(before: scalars.endIndex)
        for index in scalars.indices {
            let scalar = scalars[index]
            switch scalar.value {
            case 0...0x20, 0x7F, 0x40, 0x2F, 0x5C, 0x3F, 0x23:
                return false
            case 0x3A, 0x25:
                if !isBracketedIPv6 { return false }
            case 0x5B, 0x5D:
                if !isBracketedIPv6 || (index != scalars.startIndex && index != lastIndex) {
                    return false
                }
            default:
                // All ASCII whitespace was handled above. Preserve the
                // Unicode whitespace policy without a CharacterSet lookup
                // for every byte of ordinary DNS names.
                if scalar.value > 0x7F && CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    return false
                }
            }
        }
        return true
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func invalidURL(_ reason: String) -> NetworkError {
        NetworkError.configuration(reason: .invalidBaseURL(reason))
    }
}
