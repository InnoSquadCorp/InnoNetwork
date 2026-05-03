import Foundation

/// Decides how the networking layer reacts when `URLSession` reports an
/// HTTP redirect (3xx + `Location`) for an in-flight request.
///
/// Apple's default `URLSession` behavior follows redirects automatically and
/// **does not** strip credential headers when crossing origins. RFC 9110
/// §15.4.4 specifies that user agents MUST avoid leaking credentials to a
/// different origin on automatic redirects; the default policy implemented
/// by ``DefaultRedirectPolicy`` enforces that contract by stripping
/// `Authorization`, `Cookie`, and `Proxy-Authorization` headers when the
/// redirect target's origin (scheme + host + port) differs from the source
/// request's.
///
/// Custom adopters can implement this protocol to forbid redirects entirely,
/// limit redirect depth, restrict allowed schemes, or perform tenant-specific
/// header rewriting before the follow-up request is dispatched.
public protocol RedirectPolicy: Sendable {
    /// Called for every 3xx response with a `Location` header that
    /// `URLSession` is about to follow.
    ///
    /// - Parameters:
    ///   - request: The redirect-target request `URLSession` proposes to
    ///     send. Mutate (or replace) it before returning to alter headers,
    ///     method, or URL.
    ///   - response: The original 3xx response that triggered the redirect.
    ///   - originalRequest: The request the client originally dispatched
    ///     before any redirects were followed. Used to detect cross-origin
    ///     hops independent of intermediate redirects.
    /// - Returns: The request to follow, or `nil` to cancel the redirect
    ///   chain. Returning `nil` causes `URLSession` to deliver the 3xx
    ///   response to the caller verbatim.
    func redirect(
        request: URLRequest,
        response: HTTPURLResponse,
        originalRequest: URLRequest
    ) async -> URLRequest?
}

/// The default ``RedirectPolicy`` shipped with InnoNetwork.
///
/// Behavior:
/// - Cross-origin redirects (different scheme, host, or port from the
///   original request) have credential-bearing headers stripped:
///   `Authorization`, `Cookie`, and `Proxy-Authorization`.
/// - Same-origin redirects pass through unchanged.
/// - Non-HTTP(S) redirect targets are rejected (returns `nil`).
public struct DefaultRedirectPolicy: RedirectPolicy {
    /// Header names (case-insensitive) considered credential-bearing per
    /// RFC 9110 §15.4.4 and stripped on cross-origin redirects.
    public static let sensitiveHeaders: Set<String> = [
        "authorization",
        "cookie",
        "proxy-authorization",
    ]

    public init() {}

    public func redirect(
        request: URLRequest,
        response: HTTPURLResponse,
        originalRequest: URLRequest
    ) async -> URLRequest? {
        guard let targetURL = request.url,
              let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }

        guard !Self.isSameOrigin(originalRequest.url, targetURL) else {
            return request
        }

        var stripped = request
        let headerNames = stripped.allHTTPHeaderFields?.keys ?? [:].keys
        for name in Array(headerNames) where Self.sensitiveHeaders.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }

    /// Two URLs share an origin when their scheme, host (case-insensitive),
    /// and effective port match. A missing explicit port resolves to the
    /// scheme's default (80 for http, 443 for https).
    static func isSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              lhsScheme == rhsScheme
        else {
            return false
        }
        guard let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              lhsHost == rhsHost
        else {
            return false
        }
        return effectivePort(of: lhs, scheme: lhsScheme) == effectivePort(of: rhs, scheme: rhsScheme)
    }

    private static func effectivePort(of url: URL, scheme: String) -> Int {
        if let port = url.port { return port }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return -1
        }
    }
}
