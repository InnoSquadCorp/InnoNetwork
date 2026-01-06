import Foundation
import OSLog


public protocol NetworkLogger: Sendable {
    func log(request: URLRequest)
    func log(response: Response, isError: Bool)
    func log(error: NetworkError)
}

public struct DefaultNetworkLogger: NetworkLogger {
    public init() {}

    public func log(request: URLRequest) {
        #if DEBUG
        let url: String = request.url?.absoluteString ?? ""
        let method: String = request.httpMethod ?? "unknown method"

        var log: String = "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"
        log.append("\n\n\(method) \(url)\n")
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            log.append("header: \(headers)\n")
        }
        if let cookies = HTTPCookieStorage.shared.cookies {
            log.append("cookies: \(cookies)\n")
        }
        if let body = request.httpBody, let bodyString = String(bytes: body, encoding: String.Encoding.utf8) {
            log.append("\(bodyString)\n")
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
        response.response?.allHeaderFields.forEach {
            log.append("\($0): \($1)\n")
        }
        if let reString = String(bytes: response.data, encoding: String.Encoding.utf8) {
            log.append("\(reString)\n")
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
