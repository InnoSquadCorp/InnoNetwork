@preconcurrency import Foundation
import OSLog

public protocol NetworkLogger: Sendable {
    func log(request: URLRequest)
    func log(response: Response, isError: Bool)
    func log(error: NetworkError)
}

public struct NetworkLoggingOptions: Sendable {
    public let includeRequestBody: Bool
    public let includeResponseBody: Bool
    public let includeCookies: Bool
    public let redactSensitiveData: Bool
    public let sensitiveHeaderNames: Set<String>
    /// When `true`, ``DefaultNetworkLogger`` emits logs in release builds as
    /// well as debug. Defaults to `false`, preserving the historical
    /// debug-only behaviour. Opt-in for production-grade observability —
    /// when enabling, ensure `redactSensitiveData` remains `true` and the
    /// hosting `Logger` subsystem is configured for an appropriate
    /// retention/privacy policy.
    public let releaseLogging: Bool

    public init(
        includeRequestBody: Bool = false,
        includeResponseBody: Bool = false,
        includeCookies: Bool = false,
        redactSensitiveData: Bool = true,
        sensitiveHeaderNames: Set<String> = [
            "authorization",
            "cookie",
            "set-cookie",
            "x-api-key",
            "proxy-authorization",
            // Server-issued challenges carry realm/scheme metadata that's
            // typically benign, but commonly co-emit a Bearer error
            // descriptor that reflects the *attempted* token back to the
            // caller. Redact by default; opt-out by overriding
            // `sensitiveHeaderNames`.
            "www-authenticate",
            "proxy-authenticate",
            // Common bespoke auth carriers seen across iOS clients and
            // gateways: refresh-token endpoints, vendor token mirrors,
            // session-rotation handshakes. The names are not standardised,
            // so the allowlist has to be defensive about variants.
            "x-access-token",
            "x-refresh-token",
            "x-token",
            "x-auth-token",
            "x-csrf-token",
            "x-session-token",
        ],
        releaseLogging: Bool = false
    ) {
        self.includeRequestBody = includeRequestBody
        self.includeResponseBody = includeResponseBody
        self.includeCookies = includeCookies
        self.redactSensitiveData = redactSensitiveData
        // Normalise to lowercase up front so the redaction comparison stays
        // case-insensitive even when callers pass mixed-case names like
        // `Authorization`. The comparison site uses `key.lowercased()`, so
        // an upper-cased entry in the set would silently never match.
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        self.releaseLogging = releaseLogging
    }

    /// Safe defaults for development logs.
    public static let secureDefault = NetworkLoggingOptions()

    /// Verbose logging for local diagnostics. Avoid in CI/shared environments.
    public static let verbose = NetworkLoggingOptions(
        includeRequestBody: true,
        includeResponseBody: true,
        includeCookies: true,
        redactSensitiveData: false
    )
}

public struct DefaultNetworkLogger: NetworkLogger {
    private let options: NetworkLoggingOptions
    private let cookieStorage: HTTPCookieStorage

    public init(
        options: NetworkLoggingOptions = .secureDefault,
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        self.options = options
        self.cookieStorage = cookieStorage
    }

    /// Returns `true` when the logger should emit for the current build
    /// configuration. Debug builds always emit; release builds honour
    /// ``NetworkLoggingOptions/releaseLogging``.
    private var shouldEmit: Bool {
        #if DEBUG
        return true
        #else
        return options.releaseLogging
        #endif
    }

    public func log(request: URLRequest) {
        guard shouldEmit else { return }
        let url: String = sanitize(url: request.url, nilFallback: "")
        let method: String = request.httpMethod ?? "unknown method"

        var log: String = "[REQ] ────────────────────────────"
        log.append("\n[REQ] \(method) \(url)\n")
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            log.append("[REQ] header: \(sanitize(headers: headers))\n")
        }
        if options.includeCookies, let cookies = cookieStorage.cookies {
            log.append("[REQ] cookies: \(sanitize(cookies: cookies))\n")
        }
        if options.includeRequestBody,
            let body = request.httpBody,
            let bodyString = String(bytes: body, encoding: .utf8)
        {
            log.append("[REQ] body: \(sanitize(body: bodyString))\n")
        } else if request.httpBody != nil {
            log.append("[REQ] body: <omitted>\n")
        }
        log.append("[REQ] END \(method)")
        Logger.API.debug("\(log, privacy: .auto)")
    }

    public func log(response: Response, isError: Bool) {
        guard shouldEmit else { return }
        let request = response.request
        let url: String = sanitize(url: request?.url, nilFallback: "nil")
        let statusCode: Int = response.statusCode
        let prefix = isError ? "[ERR]" : "[RES]"

        var log: String = "\(prefix) ────────────────────────────"
        log.append("\n\(prefix) \(statusCode) \(url)\n")
        if let headers = response.response?.allHeaderFields as? [String: String] {
            sanitize(headers: headers).forEach {
                log.append("\(prefix) \($0.key): \($0.value)\n")
            }
        }
        if options.includeResponseBody,
            let responseBody = String(bytes: response.data, encoding: .utf8)
        {
            log.append("\(prefix) body: \(sanitize(body: responseBody))\n")
        } else if !response.data.isEmpty {
            log.append("\(prefix) body: <omitted>\n")
        }
        log.append("\(prefix) END HTTP (\(response.data.count)-byte body)")
        Logger.API.info("\(log, privacy: .auto)")
    }

    public func log(error: NetworkError) {
        guard shouldEmit else { return }
        if let response = error.response {
            log(response: response, isError: true)
            return
        }

        var log: String = "[ERR] ────────────────────────────"
        log.append("\n[ERR] code: \(error.errorCode)\n")
        log.append("[ERR] \(error.errorDescription ?? "unknown error")\n")
        log.append("[ERR] END HTTP")
        Logger.API.debug("\(log, privacy: .auto)")
    }

    func sanitize(headers: [String: String]) -> [String: String] {
        var sanitized = headers
        for (key, value) in headers {
            if options.redactSensitiveData,
                options.sensitiveHeaderNames.contains(key.lowercased())
            {
                sanitized[key] = "<redacted>"
            } else {
                // Strip JWT-like tokens that escape the sensitive-header
                // allowlist (e.g., custom auth headers, third-party trace
                // tokens). Defence-in-depth so a non-redacted header value
                // does not silently emit a Bearer JWT into logs.
                sanitized[key] = Self.maskJWTLikeTokens(in: value)
            }
        }
        return sanitized
    }

    func sanitize(cookies: [HTTPCookie]) -> String {
        guard options.redactSensitiveData else {
            return
                cookies
                .map { Self.maskJWTLikeTokens(in: $0.description) }
                .joined(separator: "; ")
        }
        return
            cookies
            .map { "\($0.name)=<redacted>" }
            .joined(separator: "; ")
    }

    func sanitize(body: String) -> String {
        if options.redactSensitiveData { return "<redacted>" }
        // Even when explicit body redaction is disabled (verbose logging),
        // mask JWT-like tokens so a copy/paste from logs cannot leak a
        // bearer token attacker-readable.
        return Self.maskJWTLikeTokens(in: body)
    }

    /// Compiled JWT-like pattern. Cached because `NSRegularExpression`
    /// compilation is non-trivial relative to the regex apply itself, and
    /// `maskJWTLikeTokens` runs on every emitted log string.
    ///
    /// The pattern accepts the base64url alphabet (`A-Z`, `a-z`, `0-9`,
    /// `_`, `-`) **and** the standard base64 padding (`=`) so JWTs that
    /// were re-encoded with the non-URL-safe alphabet (legacy tooling,
    /// some Java/.NET pipelines) are still masked. Segment minimum
    /// length is raised to 12 bytes — a real JWT header alone (the
    /// shortest possible segment, holding only `{"alg":"HS256"}` in
    /// base64url) is 24 chars, but high false-negative cost outweighs
    /// the tiny false-positive risk of flagging a 12-char base64url
    /// blob; lowering bounds reduces the chance that an attacker-known
    /// short header escapes redaction.
    private static let jwtPattern: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: "ey[A-Za-z0-9_=-]{12,}\\.[A-Za-z0-9_=-]{12,}\\.[A-Za-z0-9_=-]{12,}"
            )
        } catch {
            assertionFailure("JWT redaction pattern failed to compile: \(error)")
            return nil
        }
    }()

    /// Compiled AWS SigV4 `Credential=` pattern. Matches the credential
    /// scope component of `Authorization: AWS4-HMAC-SHA256 Credential=AKIA…/…`
    /// so callers logging the raw `Authorization` value through paths
    /// that bypass the structured header allowlist still see the access
    /// key redacted. The pattern targets `AKIA`/`ASIA`/`AGPA` etc.
    /// 16+ char identifiers in the Credential field.
    private static let awsSigV4Pattern: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: "(AWS4-HMAC-SHA256\\s+Credential=)[A-Z0-9]{16,}(/[^,\\s]+)?",
                options: [.caseInsensitive]
            )
        } catch {
            assertionFailure("AWS SigV4 redaction pattern failed to compile: \(error)")
            return nil
        }
    }()

    /// Replaces JWT-like tokens (`eyXXX.YYY.ZZZ` with base64url-safe segments,
    /// optionally padded with `=`) and AWS SigV4 `Credential=...` access keys
    /// in a free-form string with redaction placeholders. Used as a
    /// defence-in-depth pass on log strings that escape the structured
    /// `header`/`body` paths — for example error descriptions that interpolate
    /// raw response bodies or custom diagnostic suffixes appended by
    /// interceptors.
    static func maskJWTLikeTokens(in string: String) -> String {
        var current = string
        if current.contains("ey"), let jwtPattern {
            let range = NSRange(current.startIndex..., in: current)
            current = jwtPattern.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: "<redacted-jwt>"
            )
        }
        if current.range(of: "AWS4-HMAC-SHA256", options: .caseInsensitive) != nil,
            let awsSigV4Pattern
        {
            let range = NSRange(current.startIndex..., in: current)
            current = awsSigV4Pattern.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: "$1<redacted-aws-credential>"
            )
        }
        return current
    }

    func sanitize(url: URL?, nilFallback: String = "") -> String {
        guard let url else { return nilFallback }
        guard options.redactSensitiveData else { return url.absoluteString }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        if components.user != nil { components.user = nil }
        if components.password != nil { components.password = nil }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.map {
                URLQueryItem(name: $0.name, value: $0.value == nil ? nil : "<redacted>")
            }
        }

        return components.string ?? url.absoluteString
    }
}

public struct NoOpNetworkLogger: NetworkLogger {
    public init() {}

    public func log(request: URLRequest) {}

    public func log(response: Response, isError: Bool) {}

    public func log(error: NetworkError) {}
}
