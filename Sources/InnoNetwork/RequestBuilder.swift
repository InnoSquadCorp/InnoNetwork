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
        var targetURL = try EndpointPathBuilder.makeURL(baseURL: configuration.baseURL, endpointPath: executable.path)
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
        request.allHTTPHeaderFields = executable.headers.dictionary
        if payload.hasBody, let bodyContentType {
            request.setValue(bodyContentType, forHTTPHeaderField: "Content-Type")
        }
        request.cachePolicy = configuration.cachePolicy
        request.timeoutInterval = configuration.timeout
        request.httpBody = httpBody
        return BuiltRequest(request: request, bodySource: bodySource)
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
