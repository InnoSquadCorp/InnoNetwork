import Foundation

/// Session bearer authentication required by an endpoint.
///
/// This value governs only ``RefreshTokenPolicy``. Request interceptors and
/// request signers are explicit, orthogonal capabilities because the library
/// cannot infer whether an arbitrary adapter or signature establishes the
/// principal expected by a server.
public enum SessionAuthentication: Sendable, Hashable {
    /// Never invoke the configured refresh-token policy for this endpoint.
    case anonymous
    /// Apply a current token and allow refresh replay when a policy is
    /// configured, but permit an anonymous request when it is absent.
    case optional
    /// Require a refresh-token policy and obtain a token before the first
    /// transport attempt. Token acquisition failures are surfaced without
    /// sending an anonymous request.
    case required
}

/// Fluent, builder-style alternative to declaring a custom ``APIDefinition``.
///
/// `EndpointBuilder` is intended for the simple-case ergonomics gap in the
/// existing protocol: when a call site just needs `GET /users/42` decoding
/// `User`, declaring a dedicated `struct GetUser: APIDefinition` is overkill.
/// The builder lets the same call collapse to a single expression while still
/// flowing through the same execution pipeline (interceptors, retry policy,
/// observability, trust, etc.) as a hand-written definition:
///
/// ```swift
/// let user = try await client.request(
///     EndpointBuilder<User>.get("/users/\(id)")
/// )
///
/// let post = try await client.request(
///     EndpointBuilder<Post>
///         .post("/posts")
///         .body(CreatePost(title: "Hello", body: "World"))
///         .header("Idempotency-Key", value: idempotencyKey)
/// )
///
/// // form-url-encoded login
/// let token = try await client.request(
///     EndpointBuilder<EmptyResponse>
///         .post("/login")
///         .body(credentials)
///         .transport(.formURLEncoded())
///         .decoding(Token.self)
/// )
/// ```
///
/// `EndpointBuilder` deliberately exposes only request-shape concerns (method,
/// path, query/body parameters, headers, transport, acceptable status codes).
/// Cross-cutting behaviour — interceptors, retry policy, trust evaluation —
/// stays on ``NetworkConfiguration`` so endpoints written this way pick up the
/// same session-wide policies as a hand-written ``APIDefinition``.
///
/// For multipart uploads, streaming requests, or per-endpoint interceptor
/// chains, keep using a dedicated type that conforms to ``APIDefinition``,
/// ``MultipartAPIDefinition``, or ``StreamingAPIDefinition``.
public struct EndpointBuilder<Response: Decodable & Sendable>: APIDefinition {
    public typealias Parameter = AnyEncodable
    public typealias APIResponse = Response

    public let method: HTTPMethod
    public let path: String
    public let sessionAuthentication: SessionAuthentication
    public let parameters: AnyEncodable?
    public let headers: HTTPHeaders
    public let acceptableStatusCodes: Set<Int>?
    public let transport: TransportPolicy<Response>

    public init(
        method: HTTPMethod,
        path: String,
        authentication: SessionAuthentication = .anonymous,
        parameters: AnyEncodable? = nil,
        headers: HTTPHeaders = .default,
        acceptableStatusCodes: Set<Int>? = nil,
        transport: TransportPolicy<Response>? = nil
    ) {
        self.method = method
        self.path = path
        self.sessionAuthentication = authentication
        self.parameters = parameters
        self.acceptableStatusCodes = acceptableStatusCodes
        let resolvedTransport = transport ?? Self.defaultTransport(for: method)
        self.transport = resolvedTransport
        self.headers = headers
    }

    private static func defaultTransport(for method: HTTPMethod) -> TransportPolicy<Response> {
        method.defaultsToQueryTransport ? .query() : .json()
    }

}


// MARK: - Builder entry points

extension EndpointBuilder {
    /// Creates a GET endpoint that decodes `Response` as JSON by default.
    public static func get(_ path: String) -> Self {
        Self(method: .get, path: path)
    }

    /// Creates a POST endpoint that encodes and decodes JSON by default.
    public static func post(_ path: String) -> Self {
        Self(method: .post, path: path)
    }

    /// Creates a PUT endpoint that encodes and decodes JSON by default.
    public static func put(_ path: String) -> Self {
        Self(method: .put, path: path)
    }

    /// Creates a PATCH endpoint that encodes and decodes JSON by default.
    public static func patch(_ path: String) -> Self {
        Self(method: .patch, path: path)
    }

    /// Creates a DELETE endpoint that encodes and decodes JSON by default.
    public static func delete(_ path: String) -> Self {
        Self(method: .delete, path: path)
    }
}


// MARK: - Fluent modifiers (preserve Response type)

extension EndpointBuilder {
    /// Returns a copy of this endpoint with query parameters attached. This is
    /// intended for methods whose parameters conventionally belong in the URL,
    /// such as `GET` and `HEAD`; other methods still follow the normal
    /// ``APIDefinition`` encoding rules for their method and transport.
    public func query(_ query: some Encodable & Sendable) -> Self {
        Self(
            method: method,
            path: path,
            authentication: sessionAuthentication,
            parameters: AnyEncodable(query),
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with the supplied request body. The
    /// caller's value is wrapped in an ``AnyEncodable`` so the endpoint can
    /// travel across actor boundaries while staying `Sendable`.
    public func body(_ body: some Encodable & Sendable) -> Self {
        Self(
            method: method,
            path: path,
            authentication: sessionAuthentication,
            parameters: AnyEncodable(body),
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with a single header added or updated.
    /// Existing headers with the same name (case-insensitively) are replaced.
    public func header(_ name: String, value: String) -> Self {
        var newHeaders = headers
        newHeaders.update(name: name, value: value)
        return Self(
            method: method,
            path: path,
            authentication: sessionAuthentication,
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
    public func headers(_ headers: HTTPHeaders) -> Self {
        Self(
            method: method,
            path: path,
            authentication: sessionAuthentication,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with the supplied transport policy.
    /// Transport-derived `Content-Type` is applied later during request building
    /// only when an encoded body exists.
    public func transport(_ transport: TransportPolicy<Response>) -> Self {
        Self(
            method: method,
            path: path,
            authentication: sessionAuthentication,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }

    /// Returns a copy of this endpoint with a per-endpoint override for the
    /// set of HTTP status codes treated as success. See
    /// ``APIDefinition/acceptableStatusCodes`` for the precedence rule.
    public func acceptableStatusCodes(_ codes: Set<Int>) -> Self {
        Self(
            method: method,
            path: path,
            authentication: sessionAuthentication,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: codes,
            transport: transport
        )
    }

    /// Returns a copy with an explicit session bearer-authentication policy.
    /// Request signers remain independent and continue to run according to the
    /// endpoint and client configuration.
    public func authentication(_ authentication: SessionAuthentication) -> Self {
        Self(
            method: method,
            path: path,
            authentication: authentication,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: transport
        )
    }
}


// MARK: - Decoding promotion

extension EndpointBuilder where Response == EmptyResponse {
    /// Promotes an `EndpointBuilder<EmptyResponse>` into an endpoint that
    /// decodes the supplied type.
    /// This is the terminal step of the builder; the returned value can be
    /// passed directly to ``NetworkClient/request(_:)``.
    ///
    /// The current request-encoding shape (set via ``query(_:)``, ``body(_:)``,
    /// or ``transport(_:)``) is carried over. Response decoding is reset to
    /// the default JSON decoder for the new response type.
    public func decoding<T: Decodable & Sendable>(_ type: T.Type) -> EndpointBuilder<T> {
        EndpointBuilder<T>(
            method: method,
            path: path,
            authentication: sessionAuthentication,
            parameters: parameters,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes,
            transport: Self.transportCarryingEncoding(from: transport, to: T.self)
        )
    }

    /// Translates this endpoint's `requestEncoding` into a fresh
    /// ``TransportPolicy`` for the new response generic. Picked up by
    /// ``decoding(_:)``.
    private static func transportCarryingEncoding<T: Decodable & Sendable>(
        from transport: TransportPolicy<EmptyResponse>,
        to _: T.Type
    ) -> TransportPolicy<T> {
        switch transport.requestEncoding {
        case .json(let encoder):
            return .json(encoder: encoder)
        case .query(let encoder, let rootKey):
            return .query(encoder: encoder, rootKey: rootKey)
        case .formURLEncoded(let encoder, let rootKey):
            return .formURLEncoded(encoder: encoder, rootKey: rootKey)
        case .none:
            return noneEncodingTransportCarryingResponseShape(from: transport)
        }
    }

    private static func noneEncodingTransportCarryingResponseShape<T: Decodable & Sendable>(
        from transport: TransportPolicy<EmptyResponse>
    ) -> TransportPolicy<T> {
        switch transport.responseDecoding {
        case .json(let decoder):
            let strategy = ResponseDecodingStrategy<T>.json(decoder)
            return TransportPolicy<T>(
                requestEncoding: .none,
                responseDecoding: strategy,
                responseDecoder: AnyResponseDecoder(strategy: strategy)
            )
        case .jsonAllowingEmpty(let decoder):
            let strategy = ResponseDecodingStrategy<T>.jsonAllowingEmpty(decoder)
            return TransportPolicy<T>(
                requestEncoding: .none,
                responseDecoding: strategy,
                responseDecoder: AnyResponseDecoder(strategy: strategy)
            )
        case .custom(let decodeEmptyResponse):
            return .custom(encoding: .none) { data, response in
                _ = try decodeEmptyResponse(data, response)
                return try decodePromotedJSONResponse(data: data, response: response, as: T.self)
            }
        }
    }

    private static func decodePromotedJSONResponse<T: Decodable & Sendable>(
        data: Data,
        response: InnoNetwork.Response,
        as type: T.Type
    ) throws -> T {
        do {
            return try SharedCoders.decode(type, from: data)
        } catch {
            throw NetworkError.decoding(
                stage: .responseBody,
                underlying: SendableUnderlyingError(error),
                response: response
            )
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
