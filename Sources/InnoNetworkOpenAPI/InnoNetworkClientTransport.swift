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
/// already configured (timeouts, cache policy, cookie storage, HTTP/3,
/// custom delegate, etc.).
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

    /// Maximum number of bytes the transport will stream from the origin
    /// response body before failing the generated client's body consumer.
    /// Defaults to 50 MiB.
    public let responseBodyByteLimit: Int

    private let session: URLSession
    private static let responseBodyChunkSize = 16 * 1024

    /// Construct a transport backed by the supplied `URLSession`.
    /// - Parameters:
    ///   - session: The URLSession used to dispatch generated requests.
    ///     Construct it from
    ///     ``NetworkConfiguration/makeURLSessionConfiguration()`` to carry
    ///     session-level timeout, cache, and network-access defaults, then
    ///     mutate `URLSessionConfiguration` directly for cookie storage,
    ///     HTTP/3, TLS, or delegate-owned behavior. `NetworkConfiguration`
    ///     trust policies are evaluated by InnoNetwork's request pipeline and
    ///     are not copied into this bare generated-client transport.
    ///   - requestBodyByteLimit: Maximum collected size for outgoing
    ///     request bodies.
    ///   - responseBodyByteLimit: Maximum streamed size for incoming
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

        let (responseBytes, urlResponse) = try await session.bytes(for: urlRequest)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw InnoNetworkClientTransportError.nonHTTPResponse(urlResponse)
        }

        let normalizedResponseLimit = max(0, responseBodyByteLimit)
        if !Self.statusCodeMustNotCarryBody(httpResponse.statusCode),
            urlResponse.expectedContentLength > Int64(normalizedResponseLimit)
        {
            throw InnoNetworkClientTransportError.responseBodyTooLarge(
                limit: normalizedResponseLimit,
                received: Int(clamping: urlResponse.expectedContentLength)
            )
        }

        let response = try makeHTTPResponse(from: httpResponse)
        let responseBody = makeResponseBody(
            responseBytes,
            response: httpResponse,
            limit: normalizedResponseLimit
        )
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

    private func makeResponseBody(
        _ bytes: URLSession.AsyncBytes,
        response: HTTPURLResponse,
        limit: Int
    ) -> HTTPBody? {
        guard !Self.statusCodeMustNotCarryBody(response.statusCode) else { return nil }
        if response.expectedContentLength == 0 { return nil }

        let bodyLength: HTTPBody.Length =
            response.expectedContentLength > 0
            ? .known(response.expectedContentLength)
            : .unknown
        let stream = AsyncThrowingStream<HTTPBody.ByteChunk, any Error> { continuation in
            let task = Task {
                var iterator = bytes.makeAsyncIterator()
                var chunk: [UInt8] = []
                chunk.reserveCapacity(Self.responseBodyChunkSize)
                var received = 0

                do {
                    while let byte = try await iterator.next() {
                        received += 1
                        if received > limit {
                            throw InnoNetworkClientTransportError.responseBodyTooLarge(
                                limit: limit,
                                received: received
                            )
                        }
                        chunk.append(byte)
                        if chunk.count >= Self.responseBodyChunkSize {
                            continuation.yield(ArraySlice(chunk))
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(ArraySlice(chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
        return HTTPBody(stream, length: bodyLength)
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
            // `HTTPURLResponse.allHeaderFields` collapses repeated headers
            // (notably `Set-Cookie`, which may include commas in `Expires`)
            // into a single comma-joined string. Splitting on `, ` for that
            // case alone produces invalid cookies, but emitting a single
            // `Set-Cookie` field keeps RFC 6265 parsers that consume the
            // value as one string working — so we accept the lossy
            // collapse Foundation has already performed and add a single
            // field. Other headers are safe under RFC 9110 comma-join.
            headerFields.append(HTTPField(name: fieldName, value: valueString))
        }
        return HTTPResponse(status: status, headerFields: headerFields)
    }

    private static func statusCodeMustNotCarryBody(_ statusCode: Int) -> Bool {
        statusCode == 204 || statusCode == 205 || statusCode == 304
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
    /// The streamed response body exceeded
    /// ``InnoNetworkClientTransport/responseBodyByteLimit``. When the server
    /// reports an oversized `Content-Length`, this can be thrown by
    /// ``InnoNetworkClientTransport/send(_:body:baseURL:operationID:)`` before
    /// the body is returned. For unknown lengths, it can be thrown later while
    /// the generated client consumes the returned `HTTPBody`.
    case responseBodyTooLarge(limit: Int, received: Int)

    public var description: String {
        switch self {
        case .invalidRequestURL(let baseURL, let path):
            "InnoNetworkClientTransport: could not resolve request URL "
                + "from base \(baseURL.absoluteString) and path \(path ?? "<nil>")"
        case .nonHTTPResponse(let response):
            "InnoNetworkClientTransport: expected HTTPURLResponse, got \(type(of: response))"
        case .invalidStatusCode(let code):
            "InnoNetworkClientTransport: server returned non-recognised status code \(code)"
        case .responseBodyTooLarge(let limit, let received):
            "InnoNetworkClientTransport: response body \(received) bytes exceeded limit \(limit)"
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
