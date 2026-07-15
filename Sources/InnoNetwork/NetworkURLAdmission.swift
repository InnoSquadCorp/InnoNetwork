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

        let allowedSchemes: Set<String>
        let insecureScheme: String
        let insecureAllowed: Bool
        switch policy {
        case .http(let allowsInsecure):
            allowedSchemes = ["https", "http"]
            insecureScheme = "http"
            insecureAllowed = allowsInsecure
        case .webSocket(let allowsInsecure):
            allowedSchemes = ["wss", "ws"]
            insecureScheme = "ws"
            insecureAllowed = allowsInsecure
        }

        guard allowedSchemes.contains(scheme) else {
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
        var candidate = path
        // Decode only structural ASCII escapes. Unlike Foundation's full
        // percent decoder, an unrelated non-UTF-8 byte cannot make this check
        // give up before it reaches a later encoded dot segment.
        while true {
            let pathLike = candidate.replacingOccurrences(of: "\\", with: "/")
            if pathLike.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == "." || $0 == ".."
            }) {
                return true
            }
            let decoded = decodingStructuralPercentEscapes(candidate)
            guard decoded != candidate else {
                break
            }
            candidate = decoded
        }
        return false
    }

    private static func decodingStructuralPercentEscapes(_ value: String) -> String {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            guard input[index] == 0x25, index + 2 < input.count,
                let high = hexValue(input[index + 1]),
                let low = hexValue(input[index + 2])
            else {
                output.append(input[index])
                index += 1
                continue
            }
            let decoded = (high << 4) | low
            guard decoded == 0x25 || decoded == 0x2E || decoded == 0x2F || decoded == 0x5C else {
                output.append(contentsOf: input[index...(index + 2)])
                index += 3
                continue
            }
            output.append(decoded)
            index += 3
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// `URLComponents` decodes percent escapes in `host`, including escapes
    /// for authority delimiters such as `%40` (`@`) and `%2F` (`/`). Reject
    /// those parser-ambiguous spellings before a different networking parser
    /// can interpret the same URL with a different authority boundary.
    ///
    /// Colons and percent signs remain valid inside a bracketed IPv6 literal
    /// so IPv6 addresses and RFC 6874 zone identifiers continue to work.
    private static func isStructurallyValidHost(_ host: String) -> Bool {
        let isBracketedIPv6 = host.first == "[" && host.last == "]"
        let interior = isBracketedIPv6 ? host.dropFirst().dropLast() : host[...]

        if host.contains(":") || host.contains("%") {
            guard isBracketedIPv6 else { return false }
        }
        if host.contains("[") || host.contains("]") {
            guard isBracketedIPv6,
                !interior.contains("["),
                !interior.contains("]")
            else { return false }
        }

        let ambiguousDelimiters: Set<Unicode.Scalar> = ["@", "/", "\\", "?", "#"]
        return !host.unicodeScalars.contains { scalar in
            scalar.value <= 0x20
                || scalar.value == 0x7F
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || ambiguousDelimiters.contains(scalar)
        }
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
