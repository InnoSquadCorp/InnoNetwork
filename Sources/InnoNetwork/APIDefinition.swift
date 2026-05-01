import Foundation

/// Describes a request/response endpoint executed by `DefaultNetworkClient`.
///
/// `APIDefinition` exposes one transport-shape entry point — ``transport`` —
/// instead of separate properties for content type, request encoder, query
/// encoder, root key, decoder, and type-erased response decoder. Endpoints
/// that need a non-default shape build the value through the
/// ``TransportPolicy`` factories:
///
/// ```swift
/// var transport: TransportPolicy<APIResponse> { .json() }                 // POST
/// var transport: TransportPolicy<APIResponse> { .query() }                // GET
/// var transport: TransportPolicy<APIResponse> { .formURLEncoded() }
/// var transport: TransportPolicy<APIResponse> { .jsonAllowingEmpty() }    // 204-tolerant
/// var transport: TransportPolicy<APIResponse> { .custom(encoding: ..., decode: ...) }
/// ```
///
/// The default ``transport`` selects ``TransportPolicy/json(encoder:decoder:)``
/// for body-bearing methods (`POST`, `PUT`, `PATCH`, `DELETE`) and
/// ``TransportPolicy/query(encoder:rootKey:decoder:)`` for `GET`, so most
/// hand-written endpoints can omit the property entirely.
public protocol APIDefinition: Sendable {
    associatedtype Parameter: Encodable & Sendable
    associatedtype APIResponse: Decodable & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }

    /// Per-endpoint override for the set of acceptable HTTP status codes.
    ///
    /// When `nil`, the executor falls back to
    /// ``NetworkConfiguration/acceptableStatusCodes``.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Single transport-shape entry point. The default selects
    /// ``TransportPolicy/json(encoder:decoder:)`` for body-bearing methods and
    /// ``TransportPolicy/query(encoder:rootKey:decoder:)`` for `GET`.
    var transport: TransportPolicy<APIResponse> { get }
}


/// Strategy for delivering a multipart body to the URL session.
///
/// The default is ``streamingThreshold(bytes:)`` at 50 MiB so that small
/// payloads stay in memory (cheap, single-pass) while larger uploads spill
/// to a temp file and avoid jetsam. Endpoints that know they are always
/// small can opt into ``inMemory`` for the slight encoding-cost savings;
/// endpoints that always upload large media can pick ``alwaysStream``.
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
///
/// Multipart endpoints encode their bodies through ``multipartFormData`` and
/// only need ``transport`` to describe how the response is decoded. The
/// default ``transport`` is ``TransportPolicy/multipart(decoder:)``, which
/// configures a JSON response decoder.
public protocol MultipartAPIDefinition: Sendable {
    associatedtype APIResponse: Decodable & Sendable

    var multipartFormData: MultipartFormData { get }
    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }

    /// Per-endpoint override for the set of acceptable HTTP status codes.
    ///
    /// See ``APIDefinition/acceptableStatusCodes`` for semantics.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Strategy that decides whether the multipart body is encoded in memory
    /// or streamed to a temp file. Default is
    /// ``MultipartUploadStrategy/streamingThreshold(bytes:)`` at 50 MiB so that
    /// large attachments do not blow up peak memory by default. Endpoints that
    /// always upload small payloads can override with
    /// ``MultipartUploadStrategy/inMemory`` to skip the size check; endpoints
    /// that always upload large payloads can override with
    /// ``MultipartUploadStrategy/alwaysStream``.
    var uploadStrategy: MultipartUploadStrategy { get }

    /// Single transport-shape entry point. The default is
    /// ``TransportPolicy/multipart(decoder:)``.
    var transport: TransportPolicy<APIResponse> { get }
}

// MARK: - APIDefinition default extension

extension APIDefinition where Parameter == EmptyParameter {
    public var parameters: Parameter? { nil }
}

public extension APIDefinition {
    var headers: HTTPHeaders { HTTPHeaders.default }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }

    var acceptableStatusCodes: Set<Int>? { nil }

    /// Method-aware default transport: `GET` maps to a query-string transport,
    /// every other method maps to a JSON body transport. Override this
    /// property when an endpoint needs `formURLEncoded`, `multipart`, an
    /// empty-tolerant decoder, or a fully custom transport shape.
    var transport: TransportPolicy<APIResponse> {
        switch method {
        case .get:
            return .query()
        default:
            return .json()
        }
    }
}

// MARK: - MultipartAPIDefinition default extension

public extension MultipartAPIDefinition {
    var headers: HTTPHeaders {
        HTTPHeaders.default
    }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }

    var acceptableStatusCodes: Set<Int>? { nil }

    var uploadStrategy: MultipartUploadStrategy { .streamingThreshold(bytes: 50 * 1024 * 1024) }

    var transport: TransportPolicy<APIResponse> { .multipart() }
}

// MARK: - Empty response specializations

public extension APIDefinition where APIResponse: HTTPEmptyResponseDecodable {
    /// `HTTPEmptyResponseDecodable` outputs are tolerant of HTTP 204 and empty
    /// bodies by default, so the method-aware default transport routes through
    /// the empty-capable decoders.
    var transport: TransportPolicy<APIResponse> {
        switch method {
        case .get:
            return .query()
        default:
            return .jsonAllowingEmpty()
        }
    }
}

public extension MultipartAPIDefinition where APIResponse: HTTPEmptyResponseDecodable {
    var transport: TransportPolicy<APIResponse> {
        .multipart()
    }
}
