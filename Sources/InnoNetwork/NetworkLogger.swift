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
        ]
    ) {
        self.includeRequestBody = includeRequestBody
        self.includeResponseBody = includeResponseBody
        self.includeCookies = includeCookies
        self.redactSensitiveData = redactSensitiveData
        self.sensitiveHeaderNames = sensitiveHeaderNames
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

    public func log(request: URLRequest) {
        #if DEBUG
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
        #endif
    }

    public func log(response: Response, isError: Bool) {
        #if DEBUG
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
        #endif
    }

    public func log(error: NetworkError) {
        #if DEBUG
        if let response = error.response {
            log(response: response, isError: true)
            return
        }

        var log: String = "[ERR] ────────────────────────────"
        log.append("\n[ERR] code: \(error.errorCode)\n")
        log.append("[ERR] \(error.failureReason ?? error.errorDescription ?? "unknown error")\n")
        log.append("[ERR] END HTTP")
        Logger.API.debug("\(log, privacy: .auto)")
        #endif
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

    /// Replaces JWT-like tokens (`eyXXX.YYY.ZZZ` with base64url-safe segments)
    /// in a free-form string with `<redacted-jwt>`. Used as a defence-in-depth
    /// pass on log strings that escape the structured `header`/`body` paths —
    /// for example error descriptions that interpolate raw response bodies or
    /// custom diagnostic suffixes appended by interceptors.
    static func maskJWTLikeTokens(in string: String) -> String {
        if !string.contains("ey") { return string }
        let pattern = "ey[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(
            in: string,
            options: [],
            range: range,
            withTemplate: "<redacted-jwt>"
        )
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
