import Foundation
import OSLog


public protocol NetworkLogger: Sendable {
    func log(request: URLRequest)
    func log(response: Response, isError: Bool)
    func log(error: NetworkError)
}


/// Configuration for sensitive data masking in network logs
public struct LoggerMaskingOptions: Sendable {
    /// Headers that should be masked in logs
    public let sensitiveHeaders: Set<String>

    /// Whether to mask request body content
    public let maskRequestBody: Bool

    /// Whether to mask response body content
    public let maskResponseBody: Bool

    /// Whether to mask cookies
    public let maskCookies: Bool

    /// The string used to replace sensitive values
    public let maskPlaceholder: String

    /// Default sensitive headers that are commonly masked
    public static let defaultSensitiveHeaders: Set<String> = [
        "Authorization",
        "Cookie",
        "Set-Cookie",
        "X-API-Key",
        "X-Auth-Token",
        "X-Access-Token",
        "X-Refresh-Token",
        "Bearer",
        "Api-Key",
        "Secret",
        "Password",
        "Proxy-Authorization"
    ]

    /// Default options with common sensitive headers masked
    public static let `default` = LoggerMaskingOptions(
        sensitiveHeaders: defaultSensitiveHeaders,
        maskRequestBody: false,
        maskResponseBody: false,
        maskCookies: true,
        maskPlaceholder: "[MASKED]"
    )

    /// Options that disable all masking (for development only)
    public static let none = LoggerMaskingOptions(
        sensitiveHeaders: [],
        maskRequestBody: false,
        maskResponseBody: false,
        maskCookies: false,
        maskPlaceholder: "[MASKED]"
    )

    /// Options that mask everything sensitive
    public static let strict = LoggerMaskingOptions(
        sensitiveHeaders: defaultSensitiveHeaders,
        maskRequestBody: true,
        maskResponseBody: true,
        maskCookies: true,
        maskPlaceholder: "[MASKED]"
    )

    public init(
        sensitiveHeaders: Set<String> = defaultSensitiveHeaders,
        maskRequestBody: Bool = false,
        maskResponseBody: Bool = false,
        maskCookies: Bool = true,
        maskPlaceholder: String = "[MASKED]"
    ) {
        self.sensitiveHeaders = Set(sensitiveHeaders.map { $0.lowercased() })
        self.maskRequestBody = maskRequestBody
        self.maskResponseBody = maskResponseBody
        self.maskCookies = maskCookies
        self.maskPlaceholder = maskPlaceholder
    }

    /// Check if a header name should be masked
    func shouldMask(header: String) -> Bool {
        sensitiveHeaders.contains(header.lowercased())
    }

    /// Mask headers dictionary
    func maskHeaders(_ headers: [String: String]) -> [String: String] {
        var masked = headers
        for (key, _) in headers {
            if shouldMask(header: key) {
                masked[key] = maskPlaceholder
            }
        }
        return masked
    }
}


public struct DefaultNetworkLogger: NetworkLogger {
    private let maskingOptions: LoggerMaskingOptions

    public init(maskingOptions: LoggerMaskingOptions = .none) {
        self.maskingOptions = maskingOptions
    }

    public func log(request: URLRequest) {
        #if DEBUG
        let url: String = request.url?.absoluteString ?? ""
        let method: String = request.httpMethod ?? "unknown method"

        var log: String = "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"
        log.append("\n\n\(method) \(url)\n")
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            let displayHeaders = maskingOptions.maskHeaders(headers)
            log.append("header: \(displayHeaders)\n")
        }
        if maskingOptions.maskCookies {
            if HTTPCookieStorage.shared.cookies?.isEmpty == false {
                log.append("cookies: \(maskingOptions.maskPlaceholder)\n")
            }
        } else if let cookies = HTTPCookieStorage.shared.cookies {
            log.append("cookies: \(cookies)\n")
        }
        if let body = request.httpBody, let bodyString = String(bytes: body, encoding: String.Encoding.utf8) {
            if maskingOptions.maskRequestBody {
                log.append("\(maskingOptions.maskPlaceholder)\n")
            } else {
                log.append("\(bodyString)\n")
            }
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
        response.response?.allHeaderFields.forEach { key, value in
            let headerName = String(describing: key)
            if maskingOptions.shouldMask(header: headerName) {
                log.append("\(headerName): \(maskingOptions.maskPlaceholder)\n")
            } else {
                log.append("\(key): \(value)\n")
            }
        }
        if let reString = String(bytes: response.data, encoding: String.Encoding.utf8) {
            if maskingOptions.maskResponseBody {
                log.append("\(maskingOptions.maskPlaceholder)\n")
            } else {
                log.append("\(reString)\n")
            }
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
}

public struct NoOpNetworkLogger: NetworkLogger {
    public init() {}

    public func log(request: URLRequest) {}

    public func log(response: Response, isError: Bool) {}

    public func log(error: NetworkError) {}
}
