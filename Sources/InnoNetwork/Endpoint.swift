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
///         .header("X-Idempotency-Key", value: idempotencyKey)
///         .decoding(Post.self)
/// )
/// ```
///
/// `Endpoint` deliberately exposes only request-shape concerns (method, path,
/// query/body parameters, headers, content-type, acceptable status codes). Cross-cutting
/// behaviour — interceptors, retry policy, trust evaluation — stays on
/// ``NetworkConfiguration`` so endpoints written this way pick up the same
/// session-wide policies as a hand-written ``APIDefinition``.
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
    public let contentType: ContentType
    public let headers: HTTPHeaders
    public let acceptableStatusCodes: Set<Int>?

    public init(
        method: HTTPMethod,
        path: String,
        parameters: AnyEncodable? = nil,
        contentType: ContentType = .json,
        headers: HTTPHeaders = .default,
        acceptableStatusCodes: Set<Int>? = nil
    ) {
        self.method = method
        self.path = path
        self.parameters = parameters
        self.contentType = contentType
        self.headers = Self.headers(headers, applying: contentType)
        self.acceptableStatusCodes = acceptableStatusCodes
    }

    private static func headers(_ headers: HTTPHeaders, applying contentType: ContentType) -> HTTPHeaders {
        var updatedHeaders = headers
        updatedHeaders.update(.contentType("\(contentType.rawValue); charset=UTF-8"))
        return updatedHeaders
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
    /// ``APIDefinition`` encoding rules for their method and content type.
    public func query(_ query: some Encodable & Sendable) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: AnyEncodable(query),
            contentType: contentType,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes
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
            contentType: contentType,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes
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
            contentType: contentType,
            headers: newHeaders,
            acceptableStatusCodes: acceptableStatusCodes
        )
    }

    /// Returns a copy of this endpoint with the supplied header collection.
    /// Replaces the entire header set; pair with ``header(_:value:)`` if you
    /// only need to add a single field. The endpoint still reapplies its
    /// ``contentType`` as `Content-Type`, matching ``APIDefinition`` defaults.
    public func headers(_ headers: HTTPHeaders) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: parameters,
            contentType: contentType,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes
        )
    }

    /// Returns a copy of this endpoint with the supplied content-type. The
    /// endpoint's `Content-Type` header is updated immediately to match this
    /// value, mirroring ``APIDefinition`` defaults.
    public func contentType(_ contentType: ContentType) -> Endpoint<Response> {
        Endpoint(
            method: method,
            path: path,
            parameters: parameters,
            contentType: contentType,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes
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
            contentType: contentType,
            headers: headers,
            acceptableStatusCodes: codes
        )
    }
}


// MARK: - Decoding promotion

extension Endpoint where Response == EmptyResponse {
    /// Promotes an `Endpoint<EmptyResponse>` (the result of `.get(_:)`,
    /// `.post(_:)`, etc.) into an endpoint that decodes the supplied type.
    /// This is the terminal step of the builder; the returned value can be
    /// passed directly to ``NetworkClient/request(_:)``.
    public func decoding<T: Decodable & Sendable>(_ type: T.Type) -> Endpoint<T> {
        Endpoint<T>(
            method: method,
            path: path,
            parameters: parameters,
            contentType: contentType,
            headers: headers,
            acceptableStatusCodes: acceptableStatusCodes
        )
    }
}
