import Foundation
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
            "proxy-authorization"
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

    public init(options: NetworkLoggingOptions = .secureDefault) {
        self.options = options
    }

    public func log(request: URLRequest) {
        #if DEBUG
        let url: String = request.url?.absoluteString ?? ""
        let method: String = request.httpMethod ?? "unknown method"

        var log: String = "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"
        log.append("\n\n\(method) \(url)\n")
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            log.append("header: \(sanitize(headers: headers))\n")
        }
        if options.includeCookies, let cookies = HTTPCookieStorage.shared.cookies {
            log.append("cookies: \(sanitize(cookies: cookies))\n")
        }
        if options.includeRequestBody,
           let body = request.httpBody,
           let bodyString = String(bytes: body, encoding: .utf8)
        {
            log.append("\(sanitize(body: bodyString))\n")
        } else if request.httpBody != nil {
            log.append("request body: <omitted>\n")
        }
        log.append("END \(method)\n\n")
        log.append("🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀")
        Logger.API.debug("\(log, privacy: .auto)")
        #endif
    }

    public func log(response: Response, isError: Bool) {
        #if DEBUG
        let request = response.request
        let url: String = request?.url?.absoluteString ?? "nil"
        let statusCode: Int = response.statusCode

        var log: String = isError ? "💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣" : "💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌"
        log.append("\n\n\(statusCode) \(url)\n")
        if let headers = response.response?.allHeaderFields as? [String: String] {
            sanitize(headers: headers).forEach {
                log.append("\($0.key): \($0.value)\n")
            }
        }
        if options.includeResponseBody,
           let responseBody = String(bytes: response.data, encoding: .utf8)
        {
            log.append("\(sanitize(body: responseBody))\n")
        } else if !response.data.isEmpty {
            log.append("response body: <omitted>\n")
        }
        log.append("END HTTP (\(response.data.count)-byte body)\n\n")
        log.append(isError ? "💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣" : "💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌💌")
        Logger.API.info("\(log, privacy: .auto)")
        #endif
    }

    public func log(error: NetworkError) {
        #if DEBUG
        if let response = error.response {
            log(response: response, isError: true)
            return
        }

        var log: String = "💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣"
        log.append("\n\n\(error.errorCode)\n")
        log.append("\(error.failureReason ?? error.errorDescription ?? "unknown error")\n")
        log.append("END HTTP\n\n")
        log.append("💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣💣")
        Logger.API.debug("\(log, privacy: .auto)")
        #endif
    }

    func sanitize(headers: [String: String]) -> [String: String] {
        guard options.redactSensitiveData else { return headers }
        var sanitized = headers
        for key in headers.keys {
            if options.sensitiveHeaderNames.contains(key.lowercased()) {
                sanitized[key] = "<redacted>"
            }
        }
        return sanitized
    }

    func sanitize(cookies: [HTTPCookie]) -> String {
        guard options.redactSensitiveData else {
            return cookies.map(\.description).joined(separator: "; ")
        }
        return cookies
            .map { "\($0.name)=<redacted>" }
            .joined(separator: "; ")
    }

    func sanitize(body: String) -> String {
        guard options.redactSensitiveData else { return body }
        return "<redacted>"
    }
}

public struct NoOpNetworkLogger: NetworkLogger {
    public init() {}

    public func log(request: URLRequest) {}

    public func log(response: Response, isError: Bool) {}

    public func log(error: NetworkError) {}
}
