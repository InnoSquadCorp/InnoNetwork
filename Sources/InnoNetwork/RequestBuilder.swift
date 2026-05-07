import Foundation

/// Result of ``RequestBuilder/build(_:configuration:)``.
///
/// Combines the prepared ``URLRequest`` with metadata that tells the
/// ``RequestExecutor`` how to deliver the body. The body source is needed
/// because ``RequestPayload/fileURL(_:contentType:)`` requests must be
/// dispatched via `URLSession.upload(for:fromFile:)` rather than the
/// in-memory `data(for:)` path.
package struct BuiltRequest: Sendable {
    package var request: URLRequest
    package var bodySource: BodySource

    package init(request: URLRequest, bodySource: BodySource) {
        self.request = request
        self.bodySource = bodySource
    }
}

package enum BodySource: Sendable {
    /// Request body is either absent or already attached to `URLRequest.httpBody`.
    case inline
    /// Request body must be streamed from disk via `upload(for:fromFile:)`.
    case file(URL, cleanupAfterUse: Bool)
}


package struct RequestBuilder {
    package init() {}

    package func build<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration
    ) throws -> BuiltRequest {
        let payload = try executable.makePayload()

        // GET requests with a body are accepted by some servers and silently
        // dropped by others; reject them so the caller is forced to use a
        // body-bearing method instead of getting non-deterministic behaviour.
        if payload.hasBody, executable.method == .get {
            throw NetworkError.invalidRequestConfiguration(
                "HTTP GET requests must not carry a request body. Use POST or PUT for body-bearing endpoints."
            )
        }

        var targetURL = try EndpointPathBuilder.makeURL(
            baseURL: configuration.baseURL,
            endpointPath: executable.path,
            allowsInsecureHTTP: configuration.allowsInsecureHTTP
        )
        var httpBody: Data?
        var bodySource = BodySource.inline
        var bodyContentType = executable.bodyContentType

        switch payload {
        case .none:
            break
        case .data(let data):
            httpBody = data
        case .queryItems(let queryItems):
            targetURL.append(queryItems: queryItems)
        case .fileURL(let url, let contentType):
            bodySource = .file(url, cleanupAfterUse: false)
            bodyContentType = contentType
        case .temporaryFileURL(let url, let contentType):
            bodySource = .file(url, cleanupAfterUse: true)
            bodyContentType = contentType
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = executable.method.rawValue
        request.headers = executable.headers
        refreshDynamicDefaultHeaders(on: &request, configuration: configuration)
        if payload.hasBody, let bodyContentType {
            request.setValue(bodyContentType, forHTTPHeaderField: "Content-Type")
        }
        request.cachePolicy = executable.cachePolicyOverride ?? configuration.cachePolicy
        request.timeoutInterval = executable.timeoutOverride ?? configuration.timeout
        request.networkServiceType = (executable.priorityOverride ?? configuration.requestPriority).networkServiceType
        request.allowsCellularAccess =
            executable.allowsCellularAccessOverride ?? configuration.allowsCellularAccess
        request.allowsExpensiveNetworkAccess =
            executable.allowsExpensiveNetworkAccessOverride ?? configuration.allowsExpensiveNetworkAccess
        request.allowsConstrainedNetworkAccess =
            executable.allowsConstrainedNetworkAccessOverride ?? configuration.allowsConstrainedNetworkAccess
        request.httpBody = httpBody
        return BuiltRequest(request: request, bodySource: bodySource)
    }

    private func refreshDynamicDefaultHeaders(
        on request: inout URLRequest,
        configuration: NetworkConfiguration
    ) {
        replaceHeader(
            name: "User-Agent",
            defaultValue: HTTPHeader.defaultUserAgent.value,
            provider: configuration.userAgentProvider,
            on: &request
        )
        replaceHeader(
            name: "Accept-Language",
            defaultValue: HTTPHeader.defaultAcceptLanguage.value,
            provider: configuration.acceptLanguageProvider,
            on: &request
        )
    }

    private func replaceHeader(
        name: String,
        defaultValue: String,
        provider: @Sendable () -> String,
        on request: inout URLRequest
    ) {
        guard request.value(forHTTPHeaderField: name) == defaultValue else { return }
        request.setValue(provider(), forHTTPHeaderField: name)
    }
}

private extension RequestPayload {
    var hasBody: Bool {
        switch self {
        case .data, .fileURL, .temporaryFileURL:
            return true
        case .none, .queryItems:
            return false
        }
    }
}
