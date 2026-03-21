import Foundation

/// Encoded request payload values returned by ``SingleRequestExecutable/makePayload()``.
///
/// Implementers should choose the case that matches the transport policy expected by
/// ``DefaultNetworkClient``.
/// - none: No request body or query items should be attached to the outgoing request.
/// - data: A fully encoded HTTP body, such as JSON, form-url-encoded bytes, multipart data, or another transport-specific payload.
/// - queryItems: Encoded query parameters to append to the request URL.
@_spi(ProtobufSupport) public enum RequestPayload: Sendable {
    case none
    case data(Data)
    case queryItems([URLQueryItem])
}

/// SPI contract implemented by packages that plug custom request serialization into `InnoNetwork`.
///
/// Implementers are responsible for exposing request metadata, producing a transport-ready payload,
/// and decoding the final ``Response`` into `APIResponse`.
@_spi(ProtobufSupport) public protocol SingleRequestExecutable: Sendable {
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

package struct APISingleRequestExecutable<Base: APIDefinition>: SingleRequestExecutable {
    let base: Base

    package var logger: NetworkLogger { base.logger }
    package var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    package var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }
    package var method: HTTPMethod { base.method }
    package var path: String { base.path }
    package var headers: HTTPHeaders { base.headers }

    package func makePayload() throws -> RequestPayload {
        guard let parameters = base.parameters else { return .none }
        let transportPolicy = base.transportPolicy

        switch transportPolicy.requestEncoding {
        case .none:
            return .none
        case .query:
            return .queryItems(try encodeQueryItems(parameters))
        case .json(let encoder):
            return .data(try encoder.encode(parameters))
        case .formURLEncoded:
            return .data(try encodeForm(parameters))
        }
    }

    package func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.transportPolicy.responseDecoder.decode(data: data, response: response)
    }

    private func encodeQueryItems(_ parameters: Base.Parameter) throws -> [URLQueryItem] {
        do {
            switch base.transportPolicy.requestEncoding {
            case .query(let encoder, let rootKey), .formURLEncoded(let encoder, let rootKey):
                return try encoder.encode(parameters, rootKey: rootKey)
            default:
                return try base.queryEncoder.encode(parameters, rootKey: base.queryRootKey)
            }
        } catch URLQueryEncoder.EncodingError.unsupportedTopLevelValue {
            throw NetworkError.invalidRequestConfiguration(
                "Top-level scalar or array query parameters require queryRootKey to be set."
            )
        }
    }

    private func encodeForm(_ parameters: Base.Parameter) throws -> Data {
        do {
            switch base.transportPolicy.requestEncoding {
            case .formURLEncoded(let encoder, let rootKey):
                return try encoder.encodeForm(parameters, rootKey: rootKey)
            case .query(let encoder, let rootKey):
                return try encoder.encodeForm(parameters, rootKey: rootKey)
            default:
                return try base.queryEncoder.encodeForm(parameters, rootKey: base.queryRootKey)
            }
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

    package func makePayload() throws -> RequestPayload {
        .data(base.multipartFormData.encode())
    }

    package func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.transportPolicy.responseDecoder.decode(data: data, response: response)
    }
}
