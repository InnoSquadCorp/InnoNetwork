import Foundation
import HTTPTypes
import InnoNetwork
import OpenAPIRuntime

/// An `OpenAPIRuntime.ClientTransport` implementation that routes generated
/// OpenAPI client traffic through a caller-supplied `URLSession`.
///
/// This adapter complements ``OpenAPIAdapter`` / ``OpenAPIRequest``. The
/// adapter wraps an `OpenAPIRestOperation` so it can be dispatched through
/// ``DefaultNetworkClient``; the transport is the inverse direction — it
/// lets a `swift-openapi-generator`-produced `Client` dispatch its
/// generated calls through a URLSession that the host application has
/// already configured (cookie storage, HTTP/3, custom delegate, etc.).
///
/// `InnoNetworkClientTransport` does not currently flow requests through
/// `DefaultNetworkClient`'s execution pipeline. The pipeline is shaped
/// around `APIDefinition` (typed parameters, typed response, transport
/// policy, interceptors); the generated client speaks `HTTPRequest` /
/// `HTTPBody` directly without those types. Routing one through the other
/// would require synthesising opaque-typed APIDefinitions and erasing
/// type information back out, with no net behaviour gain for adopters who
/// only need the runtime contract met. Use ``OpenAPIRequest`` when you
/// want the full InnoNetwork pipeline; use this transport when the
/// generated `Client` is the entry point.
///
/// The implementation deliberately mirrors `swift-openapi-urlsession`'s
/// shape so a migration from that transport is a one-line type swap.
public final class InnoNetworkClientTransport: ClientTransport {
    /// Maximum number of bytes the transport will collect from an
    /// outgoing `HTTPBody` before forwarding to URLSession. Defaults to
    /// 50 MiB. Override when generated operations stream payloads larger
    /// than the default ceiling — but consider whether a streaming
    /// transport is a better fit at that point.
    public let requestBodyByteLimit: Int

    /// Maximum number of bytes the transport will collect from the
    /// origin response body before handing it to the generated client.
    /// Defaults to 50 MiB.
    public let responseBodyByteLimit: Int

    private let session: URLSession

    /// Construct a transport backed by the supplied `URLSession`.
    /// - Parameters:
    ///   - session: The URLSession used to dispatch generated requests.
    ///     Construct it from
    ///     ``NetworkConfiguration/makeURLSessionConfiguration()`` to inherit
    ///     the same TLS / timeout / cookie posture the rest of the app
    ///     uses, or pass `.shared` for stand-alone use.
    ///   - requestBodyByteLimit: Maximum collected size for outgoing
    ///     request bodies.
    ///   - responseBodyByteLimit: Maximum collected size for incoming
    ///     response bodies.
    public init(
        session: URLSession,
        requestBodyByteLimit: Int = 50 * 1024 * 1024,
        responseBodyByteLimit: Int = 50 * 1024 * 1024
    ) {
        self.session = session
        self.requestBodyByteLimit = requestBodyByteLimit
        self.responseBodyByteLimit = responseBodyByteLimit
    }

    public func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let urlRequest = try await makeURLRequest(
            request: request,
            body: body,
            baseURL: baseURL
        )

        let (responseData, urlResponse) = try await session.data(for: urlRequest)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw InnoNetworkClientTransportError.nonHTTPResponse(urlResponse)
        }

        let response = try makeHTTPResponse(from: httpResponse)
        let responseBody = responseData.isEmpty
            ? nil
            : HTTPBody(ArraySlice(responseData))
        return (response, responseBody)
    }

    private func makeURLRequest(
        request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL
    ) async throws -> URLRequest {
        guard
            let path = request.path,
            let resolved = URL(string: path, relativeTo: baseURL)
        else {
            throw InnoNetworkClientTransportError.invalidRequestURL(
                baseURL: baseURL,
                path: request.path
            )
        }

        var urlRequest = URLRequest(url: resolved)
        urlRequest.httpMethod = request.method.rawValue

        for field in request.headerFields {
            urlRequest.addValue(field.value, forHTTPHeaderField: field.name.canonicalName)
        }

        if let body {
            let collected = try await Data(
                collecting: body,
                upTo: requestBodyByteLimit
            )
            if !collected.isEmpty {
                urlRequest.httpBody = collected
            }
        }

        return urlRequest
    }

    private func makeHTTPResponse(from response: HTTPURLResponse) throws -> HTTPResponse {
        guard let status = HTTPResponse.Status(code: response.statusCode).optional else {
            throw InnoNetworkClientTransportError.invalidStatusCode(response.statusCode)
        }

        var headerFields = HTTPFields()
        for (name, value) in response.allHeaderFields {
            guard
                let nameString = name as? String,
                let valueString = value as? String,
                let fieldName = HTTPField.Name(nameString)
            else { continue }
            headerFields.append(HTTPField(name: fieldName, value: valueString))
        }
        return HTTPResponse(status: status, headerFields: headerFields)
    }
}

/// Errors raised by ``InnoNetworkClientTransport``.
public enum InnoNetworkClientTransportError: Error, CustomStringConvertible {
    /// The combination of base URL and request path could not be resolved
    /// to a concrete URL.
    case invalidRequestURL(baseURL: URL, path: String?)
    /// URLSession returned a non-`HTTPURLResponse` (extremely rare, e.g.
    /// for `file://` overrides).
    case nonHTTPResponse(URLResponse)
    /// The origin returned a status code outside the IANA-recognised
    /// range, so `HTTPResponse.Status(code:)` rejected it.
    case invalidStatusCode(Int)

    public var description: String {
        switch self {
        case .invalidRequestURL(let baseURL, let path):
            "InnoNetworkClientTransport: could not resolve request URL "
                + "from base \(baseURL.absoluteString) and path \(path ?? "<nil>")"
        case .nonHTTPResponse(let response):
            "InnoNetworkClientTransport: expected HTTPURLResponse, got \(type(of: response))"
        case .invalidStatusCode(let code):
            "InnoNetworkClientTransport: server returned non-recognised status code \(code)"
        }
    }
}

private extension HTTPResponse.Status {
    /// Treats `unrecognised`-kind statuses as `nil` so the caller can map
    /// to a transport error rather than silently propagate an invalid
    /// HTTP response.
    var optional: HTTPResponse.Status? {
        kind == .invalid ? nil : self
    }
}
