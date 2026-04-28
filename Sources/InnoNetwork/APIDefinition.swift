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

    /// Per-endpoint override for the set of acceptable HTTP status codes.
    ///
    /// When `nil`, the executor falls back to
    /// ``NetworkConfiguration/acceptableStatusCodes``. Set this on a specific
    /// endpoint when it should accept (or reject) status codes that the
    /// session-wide default does not — for example, an endpoint that treats
    /// `304 Not Modified` as success while every other endpoint treats it as
    /// failure.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Optional stub payload returned in place of executing the request.
    ///
    /// When non-`nil` and ``sampleBehavior`` is anything other than
    /// ``StubBehavior/never``, ``DefaultNetworkClient/request(_:)`` short-
    /// circuits the transport pipeline and returns this value. The default
    /// implementation is `nil`, which preserves the historical (live)
    /// behaviour for endpoints that do not opt into stubbing.
    ///
    /// Stubs are intended for SwiftUI previews, unit tests, and developer
    /// builds; they bypass interceptors, retry policy, observability, and
    /// trust evaluation.
    var sampleResponse: APIResponse? { get }

    /// Strategy that decides whether ``sampleResponse`` is delivered and
    /// after what optional delay. Defaults to ``StubBehavior/never`` so
    /// endpoints that simply expose a sample payload (for previews, etc.)
    /// still hit the real network at runtime.
    var sampleBehavior: StubBehavior { get }
}


/// Strategy for delivering a multipart body to the URL session.
///
/// The default is ``inMemory`` for backward compatibility. Endpoints that
/// upload large attachments should switch to ``streamingThreshold(bytes:)``
/// or ``alwaysStream`` to bound peak memory.
public enum MultipartUploadStrategy: Sendable, Equatable {
    /// Always encode the multipart body into a single in-memory `Data` and
    /// attach it to the request. Cheap for small payloads; risks jetsam on
    /// large media.
    case inMemory

    /// Encode in memory when the estimated body size is at or below `bytes`,
    /// otherwise stream the body to a temp file and upload via
    /// `URLSession.upload(for:fromFile:)`. Use this when the same endpoint
    /// receives both small and large payloads.
    case streamingThreshold(bytes: Int64)

    /// Always stream the body to a temp file before uploading. Ensures peak
    /// memory stays bounded regardless of body size.
    case alwaysStream
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

    /// Per-endpoint override for the set of acceptable HTTP status codes.
    ///
    /// See ``APIDefinition/acceptableStatusCodes`` for semantics.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Strategy that decides whether the multipart body is encoded in memory
    /// or streamed to a temp file. Default is ``MultipartUploadStrategy/inMemory``
    /// so existing endpoints keep current behavior; large-attachment endpoints
    /// should opt in to ``MultipartUploadStrategy/streamingThreshold(bytes:)``
    /// or ``MultipartUploadStrategy/alwaysStream``.
    var uploadStrategy: MultipartUploadStrategy { get }
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

    var acceptableStatusCodes: Set<Int>? { nil }

    var uploadStrategy: MultipartUploadStrategy { .inMemory }
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

    var acceptableStatusCodes: Set<Int>? { nil }

    var sampleResponse: APIResponse? { nil }

    var sampleBehavior: StubBehavior { .never }
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
