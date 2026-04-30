import Foundation

/// Fluent, builder-style alternative to declaring a custom ``APIDefinition``.
///
/// `Endpoint` is intended for the simple-case ergonomics gap in the existing
/// protocol: when a call site just needs `GET /users/42` decoding `User`,
/// declaring a dedicated `struct GetUser: APIDefinition` is overkill. The
/// builder lets the same call collapse to a single expression while still
/// flowing through the same execution pipeline (interceptors, retry policy,
/// observability, trust, etc.) as a hand-written definition:
///
/// ```swift
/// let user = try await client.request(
///     Endpoint.get("/users/\(id)").decoding(User.self)
/// )
///
/// let post = try await client.request(
///     Endpoint.post("/posts")
///         .body(CreatePost(title: "Hello", body: "World"))
///         .header("Idempotency-Key", value: idempotencyKey)
///         .decoding(Post.self)
/// )
///
/// // form-url-encoded login
/// let token = try await client.request(
///     Endpoint.post("/login")
///         .body(credentials)
///         .transport(.formURLEncoded())
///         .decoding(Token.self)
/// )
/// ```
///
/// `Endpoint` deliberately exposes only request-shape concerns (method, path,
/// query/body parameters, headers, transport, acceptable status codes).
/// Cross-cutting behaviour — interceptors, retry policy, trust evaluation —
/// stays on ``NetworkConfiguration`` so endpoints written this way pick up the
/// same session-wide policies as a hand-written ``APIDefinition``.
///
/// For multipart uploads, streaming requests, or per-endpoint interceptor
/// chains, keep using a dedicated type that conforms to ``APIDefinition``,
/// ``MultipartAPIDefinition``, or ``StreamingAPIDefinition``.
public struct Endpoint<Response: Decodable & Sendable>: APIDefinition {
    public typealias Parameter = AnyEncodable
    public typealias APIResponse = Response

    public let method: HTTPMethod
    public let path: String
    public let parameters: AnyEncodable?
    public let headers: HTTPHeaders
    public let acceptableStatusCodes: Set<Int>?
    public let transport: TransportPolicy<Response>

    public init(
        method: HTTPMethod,
        path: String,
        parameters: AnyEncodable? = nil,
        headers: HTTPHeaders = .default,
        acceptableStatusCodes: Set<Int>? = nil,
        transport: TransportPolicy<Response>? = nil
    ) {
        self.method = method
        self.path = path
        self.parameters = parameters
        self.acceptableStatusCodes = acceptableStatusCodes
        let resolvedTransport = transport ?? Self.defaultTransport(for: method)
        self.transport = resolvedTransport
        self.headers = headers
    }

    private static func defaultTransport(for method: HTTPMethod) -> TransportPolicy<Response> {
        method == .get ? .query() : .json()
    }

}


// MARK: - Builder entry points

extension Endpoint where Response == EmptyResponse {
    public static func get(_ path: String) -> Endpoint<EmptyResponse> {
        Endpoint(method: .get, path: path)
    }

    public static func post(_ path: String) -> Endpoint<EmptyResponse> {
        Endpoint(method: .post, path: path)
    }

    public static func put(_ path: String) -> Endpoint<EmptyResponse> {
        Endpoint(method: .put, path: path)
    }

    public static func patch(_ path: String) -> Endpoint<EmptyResponse> {
        Endpoint(method: .patch, path: path)
    }

    public static func delete(_ path: String) -> Endpoint<EmptyResponse> {
        Endpoint(method: .delete, path: path)
    }
}


// MARK: - Fluent modifiers (preserve Response type)

extension Endpoint {
    /// Returns a copy of this endpoint with query parameters attached. This is
    /// intended for `GET` endpoints; non-`GET` methods still follow the normal
    /// ``APIDefinition`` encoding rules for their method and transport.
    public func query(_ query: some Encodable & Sendable) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: AnyEncodable(query),
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with the supplied request body. The
    /// caller's value is wrapped in an ``AnyEncodable`` so the endpoint can
    /// travel across actor boundaries while staying `Sendable`.
    public func body(_ body: some Encodable & Sendable) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: AnyEncodable(body),
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with a single header added or updated.
    /// Existing headers with the same name (case-insensitively) are replaced.
    public func header(_ name: String, value: String) -> Endpoint<Response> {
        var newHeaders = headers
        newHeaders.update(name: name, value: value)
        return Endpoint(
            method: method,
            path: path,
            parameters: parameters,
            headers: newHeaders,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with the supplied header collection.
    /// Replaces the entire header set; pair with ``header(_:value:)`` if you
    /// only need to add a single field. Transport-derived `Content-Type` is
    /// applied later during request building only when an encoded body exists.
    public func headers(_ headers: HTTPHeaders) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with the supplied transport policy.
    /// Transport-derived `Content-Type` is applied later during request building
    /// only when an encoded body exists.
    public func transport(_ transport: TransportPolicy<Response>) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with a per-endpoint override for the
    /// set of HTTP status codes treated as success. See
    /// ``APIDefinition/acceptableStatusCodes`` for the precedence rule.
    public func acceptableStatusCodes(_ codes: Set<Int>) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: codes,
            transport: transport
        )
    }
}


// MARK: - Decoding promotion

extension Endpoint where Response == EmptyResponse {
    /// Promotes an `Endpoint<EmptyResponse>` (the result of `.get(_:)`,
    /// `.post(_:)`, etc.) into an endpoint that decodes the supplied type.
    /// This is the terminal step of the builder; the returned value can be
    /// passed directly to ``NetworkClient/request(_:)``.
    ///
    /// The current request-encoding shape (set via ``query(_:)``, ``body(_:)``,
    /// or ``transport(_:)``) is carried over. Response decoding is reset to
    /// the default JSON decoder for the new response type.
    public func decoding<T: Decodable & Sendable>(_ type: T.Type) -> Endpoint<T> {
        Endpoint<T>(
            method: method,
            path: path,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: Self.transportCarryingEncoding(transport.requestEncoding, to: T.self)
        )
    }

    /// Translates this endpoint's `requestEncoding` into a fresh
    /// ``TransportPolicy`` for the new response generic. Picked up by
    /// ``decoding(_:)``.
    private static func transportCarryingEncoding<T: Decodable & Sendable>(
        _ encoding: RequestEncodingPolicy,
        to type: T.Type
    ) -> TransportPolicy<T> {
        switch encoding {
        case .json(let encoder):
            return .json(encoder: encoder)
        case .query(let encoder, let rootKey):
            return .query(encoder: encoder, rootKey: rootKey)
        case .formURLEncoded(let encoder, let rootKey):
            return .formURLEncoded(encoder: encoder, rootKey: rootKey)
        case .none:
            return .multipart()
        }
    }
}


// MARK: - Content-Type header derivation

extension RequestEncodingPolicy {
    /// `Content-Type` header value implied by this encoding policy, if any.
    /// Used by the request builder to apply automatic body headers only when
    /// an encoded request body exists.
    var contentTypeHeader: String? {
        switch self {
        case .json:
            return "\(ContentType.json.rawValue); charset=UTF-8"
        case .formURLEncoded:
            return "\(ContentType.formUrlEncoded.rawValue); charset=UTF-8"
        case .query, .none:
            return nil
        }
    }
}
