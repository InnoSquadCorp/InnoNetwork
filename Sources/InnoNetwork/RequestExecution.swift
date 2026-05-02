import Foundation

/// Encoded request payload values returned by ``SingleRequestExecutable/makePayload()``.
///
/// Implementers should choose the case that matches the transport policy expected by
/// ``DefaultNetworkClient``.
/// - none: No request body or query items should be attached to the outgoing request.
/// - data: A fully encoded HTTP body, such as JSON, form-url-encoded bytes, multipart data, or another transport-specific payload.
/// - queryItems: Encoded query parameters to append to the request URL.
/// - fileURL: A file on disk to be streamed via `URLSession.upload(for:fromFile:)`.
///   Used for large multipart uploads that would otherwise exhaust memory if
///   loaded into a `Data`. The associated `contentType` is set as the
///   request's `Content-Type` header. The caller owns the file lifecycle.
/// - temporaryFileURL: A file created by InnoNetwork for this one request.
///   The executor removes it after upload completion, failure, or cancellation.
@_spi(GeneratedClientSupport) public enum RequestPayload: Sendable {
    case none
    case data(Data)
    case queryItems([URLQueryItem])
    case fileURL(URL, contentType: String)
    case temporaryFileURL(URL, contentType: String)
}

/// Low-level request execution contract implemented by packages that plug custom
/// serialization and decoding into `InnoNetwork`.
///
/// Implementers are responsible for exposing request metadata, producing a transport-ready payload,
/// and decoding the final ``Response`` into `APIResponse`.
///
/// Most consumers should continue using ``APIDefinition`` and
/// ``DefaultNetworkClient/request(_:)``. Reach for this protocol only when you are
/// building a higher-level policy layer that needs to adapt its own request contract
/// onto `InnoNetwork`'s execution engine via ``LowLevelNetworkClient/perform(_:)``.
@_spi(GeneratedClientSupport) public protocol SingleRequestExecutable: Sendable {
    associatedtype APIResponse: Sendable

    /// Logger attached to the request lifecycle.
    var logger: NetworkLogger { get }
    /// Request interceptors applied before the transport executes.
    var requestInterceptors: [RequestInterceptor] { get }
    /// Response interceptors applied after the transport completes.
    var responseInterceptors: [ResponseInterceptor] { get }
    /// HTTP method used for the outgoing request.
    var method: HTTPMethod { get }
    /// Path component appended to the configured base URL.
    var path: String { get }
    /// HTTP headers attached to the outgoing request.
    var headers: HTTPHeaders { get }
    /// Content type derived from the payload encoding, when the request carries
    /// a body. The request builder applies this after endpoint headers and
    /// before request interceptors, so interceptors remain the final authority.
    var bodyContentType: String? { get }

    /// Optional override for the set of acceptable HTTP status codes on this
    /// request. When `nil`, the executor falls back to
    /// ``NetworkConfiguration/acceptableStatusCodes``.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Whether this request requires a configured ``RefreshTokenPolicy`` before
    /// execution. Generated and fluent endpoint paths use this to make
    /// auth-required APIs fail early when the client was configured as public.
    var requiresRefreshTokenPolicy: Bool { get }

    /// Produces the encoded payload for the request.
    ///
    /// - Returns: A ``RequestPayload`` that matches the expected request transport semantics.
    /// - Throws: Any serialization error encountered while preparing the payload. Implementers should throw
    ///   a consumer-facing `NetworkError` when request configuration is invalid.
    func makePayload() throws -> RequestPayload
    /// Decodes transport output into the typed response value.
    ///
    /// - Parameters:
    ///   - data: Raw response body returned by the transport.
    ///   - response: Metadata describing the completed HTTP response.
    /// - Returns: The fully decoded `APIResponse` value.
    /// - Throws: Any decoding or validation error produced while interpreting the response body.
    func decode(data: Data, response: Response) throws -> APIResponse
}

@_spi(GeneratedClientSupport) public extension SingleRequestExecutable {
    /// Default override is `nil`, meaning the session-wide
    /// ``NetworkConfiguration/acceptableStatusCodes`` applies.
    var acceptableStatusCodes: Set<Int>? { nil }
    /// Default body content type is absent; custom executables that return
    /// ``RequestPayload/data(_:)`` or file payloads should override this when
    /// they want InnoNetwork to set `Content-Type`.
    var bodyContentType: String? { nil }
    /// Default executable contracts are public unless their adapter opts into
    /// the auth-required lane.
    var requiresRefreshTokenPolicy: Bool { false }
}

package struct APISingleRequestExecutable<Base: APIDefinition>: SingleRequestExecutable {
    let base: Base

    package var logger: NetworkLogger { base.logger }
    package var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    package var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }
    package var method: HTTPMethod { base.method }
    package var path: String { base.path }
    package var headers: HTTPHeaders { base.headers }
    package var acceptableStatusCodes: Set<Int>? { base.acceptableStatusCodes }
    package var requiresRefreshTokenPolicy: Bool { Base.Auth.self == AuthRequiredScope.self }
    package var bodyContentType: String? {
        guard base.parameters != nil else { return nil }
        return base.transport.requestEncoding.contentTypeHeader
    }

    package func makePayload() throws -> RequestPayload {
        guard let parameters = base.parameters else { return .none }
        let transport = base.transport

        switch transport.requestEncoding {
        case .none:
            throw NetworkError.invalidRequestConfiguration(
                "Request parameters cannot be encoded with RequestEncodingPolicy.none. Use MultipartAPIDefinition for multipart bodies, or choose .json, .query, .formURLEncoded, or .custom with an explicit payload strategy."
            )
        case .query(let encoder, let rootKey):
            return .queryItems(try encodeQueryItems(parameters, encoder: encoder, rootKey: rootKey))
        case .json(let encoder):
            return .data(try encoder.encode(parameters))
        case .formURLEncoded(let encoder, let rootKey):
            return .data(try encodeForm(parameters, encoder: encoder, rootKey: rootKey))
        }
    }

    package func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.transport.responseDecoder.decode(data: data, response: response)
    }

    private func encodeQueryItems(
        _ parameters: Base.Parameter,
        encoder: URLQueryEncoder,
        rootKey: String?
    ) throws -> [URLQueryItem] {
        do {
            return try encoder.encode(parameters, rootKey: rootKey)
        } catch URLQueryEncoder.EncodingError.unsupportedTopLevelValue {
            throw NetworkError.invalidRequestConfiguration(
                "Top-level scalar or array query parameters require queryRootKey to be set."
            )
        }
    }

    private func encodeForm(
        _ parameters: Base.Parameter,
        encoder: URLQueryEncoder,
        rootKey: String?
    ) throws -> Data {
        do {
            return try encoder.encodeForm(parameters, rootKey: rootKey)
        } catch URLQueryEncoder.EncodingError.unsupportedTopLevelValue {
            throw NetworkError.invalidRequestConfiguration(
                "Top-level scalar or array form parameters require queryRootKey to be set."
            )
        }
    }
}

package struct MultipartSingleRequestExecutable<Base: MultipartAPIDefinition>: SingleRequestExecutable {
    let base: Base

    package var logger: NetworkLogger { base.logger }
    package var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    package var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }
    package var method: HTTPMethod { base.method }
    package var path: String { base.path }
    package var headers: HTTPHeaders { base.headers }
    package var acceptableStatusCodes: Set<Int>? { base.acceptableStatusCodes }
    package var bodyContentType: String? { base.multipartFormData.contentTypeHeader }
    package var requiresRefreshTokenPolicy: Bool { Base.Auth.self == AuthRequiredScope.self }

    package func makePayload() throws -> RequestPayload {
        let formData = base.multipartFormData
        switch base.uploadStrategy {
        case .inMemory:
            return .data(formData.encode())
        case .alwaysStream:
            return try Self.streamPayload(formData: formData)
        case .streamingThreshold(let bytes):
            if formData.estimatedEncodedSize > bytes {
                return try Self.streamPayload(formData: formData)
            }
            return .data(formData.encode())
        }
    }

    private static func streamPayload(formData: MultipartFormData) throws -> RequestPayload {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempFile = tempDirectory.appendingPathComponent("innonetwork.multipart.\(UUID().uuidString)")
        try formData.writeEncodedData(to: tempFile)
        return .temporaryFileURL(tempFile, contentType: formData.contentTypeHeader)
    }

    package func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.transport.responseDecoder.decode(data: data, response: response)
    }
}
