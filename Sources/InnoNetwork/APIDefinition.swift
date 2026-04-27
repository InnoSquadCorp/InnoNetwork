import Foundation


/// Describes a request/response endpoint executed by `DefaultNetworkClient`.
public protocol APIDefinition: Sendable {
    associatedtype Parameter: Encodable & Sendable
    associatedtype APIResponse: Decodable & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }

    var contentType: ContentType { get }
    /// Encoder used to serialize request body parameters as JSON.
    var requestEncoder: JSONEncoder { get }
    /// Encoder used to serialize query-string and form-url-encoded parameters.
    var queryEncoder: URLQueryEncoder { get }
    /// Optional root key used when wrapping top-level query or form parameters.
    var queryRootKey: String? { get }
    /// Decoder used by the default JSON response decoding strategy.
    var decoder: JSONDecoder { get }
    /// Type-erased decoder used to transform the HTTP response body into `APIResponse`.
    var responseDecoder: AnyResponseDecoder<APIResponse> { get }
    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
}


/// Describes a multipart endpoint executed by `DefaultNetworkClient`.
public protocol MultipartAPIDefinition: Sendable {
    associatedtype APIResponse: Decodable & Sendable

    var multipartFormData: MultipartFormData { get }
    var method: HTTPMethod { get }
    var path: String { get }

    var decoder: JSONDecoder { get }
    var responseDecoder: AnyResponseDecoder<APIResponse> { get }
    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
}

extension APIDefinition {
    var transportPolicy: TransportPolicy<APIResponse> {
        TransportPolicy(
            requestEncoding: requestEncodingPolicy,
            responseDecoding: responseDecodingStrategy,
            responseDecoder: responseDecoder
        )
    }

    var requestEncodingPolicy: RequestEncodingPolicy {
        switch method {
        case .get:
            return .query(queryEncoder, rootKey: queryRootKey)
        default:
            switch contentType {
            case .json:
                return .json(requestEncoder)
            case .formUrlEncoded:
                return .formURLEncoded(queryEncoder, rootKey: queryRootKey)
            case .multipartFormData:
                return .none
            default:
                return .json(requestEncoder)
            }
        }
    }

    var responseDecodingStrategy: ResponseDecodingStrategy<APIResponse> {
        .json(decoder)
    }
}

extension MultipartAPIDefinition {
    var transportPolicy: TransportPolicy<APIResponse> {
        TransportPolicy(
            requestEncoding: requestEncodingPolicy,
            responseDecoding: responseDecodingStrategy,
            responseDecoder: responseDecoder
        )
    }

    var requestEncodingPolicy: RequestEncodingPolicy { .none }

    var responseDecodingStrategy: ResponseDecodingStrategy<APIResponse> {
        .json(decoder)
    }
}


public extension MultipartAPIDefinition {
    var decoder: JSONDecoder { makeDefaultResponseDecoder() }
    var responseDecoder: AnyResponseDecoder<APIResponse> { AnyResponseDecoder(strategy: responseDecodingStrategy) }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.contentType(multipartFormData.contentTypeHeader))
        return defaultHeaders
    }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }
}

extension APIDefinition where Parameter == EmptyParameter {
    public var parameters: Parameter? { nil }
}

public extension APIDefinition {
    var contentType: ContentType { .json }

    var requestEncoder: JSONEncoder { makeDefaultRequestEncoder() }

    var queryEncoder: URLQueryEncoder { URLQueryEncoder() }

    var queryRootKey: String? { nil }

    var decoder: JSONDecoder { makeDefaultResponseDecoder() }
    var responseDecoder: AnyResponseDecoder<APIResponse> { AnyResponseDecoder(strategy: responseDecodingStrategy) }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.contentType("\(contentType.rawValue); charset=UTF-8"))
        return defaultHeaders
    }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }
}

extension APIDefinition where APIResponse: HTTPEmptyResponseDecodable {
    var responseDecodingStrategy: ResponseDecodingStrategy<APIResponse> { .jsonAllowingEmpty(decoder) }
}

extension MultipartAPIDefinition where APIResponse: HTTPEmptyResponseDecodable {
    var responseDecodingStrategy: ResponseDecodingStrategy<APIResponse> { .jsonAllowingEmpty(decoder) }
}

public extension APIDefinition where APIResponse: HTTPEmptyResponseDecodable {
    var responseDecoder: AnyResponseDecoder<APIResponse> { AnyResponseDecoder(strategy: responseDecodingStrategy) }
}

public extension MultipartAPIDefinition where APIResponse: HTTPEmptyResponseDecodable {
    var responseDecoder: AnyResponseDecoder<APIResponse> { AnyResponseDecoder(strategy: responseDecodingStrategy) }
}
