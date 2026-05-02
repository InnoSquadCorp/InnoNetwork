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
///
/// HTTP envelope requirements (method, path, headers, interceptors,
/// status-code acceptance, transport) are inherited from
/// ``EndpointShape``; `APIDefinition` adds only the body-strategy
/// surface (`parameters`).
public protocol APIDefinition: EndpointShape {
    associatedtype Parameter: Encodable & Sendable

    var parameters: Parameter? { get }
}


/// Strategy for delivering a multipart body to the URL session.
///
/// The default is ``platformDefault`` — a memory-aware
/// ``streamingThreshold(bytes:)`` that picks 16 MiB on memory-constrained
/// platforms (iOS, watchOS, tvOS) and 50 MiB on platforms with more
/// headroom (macOS, visionOS). Small payloads stay in memory (cheap,
/// single-pass) while larger uploads spill to a temp file and avoid
/// jetsam. Endpoints that know they are always small can opt into
/// ``inMemory`` for the slight encoding-cost savings; endpoints that
/// always upload large media can pick ``alwaysStream``.
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

    /// Platform-aware default: ``streamingThreshold(bytes:)`` sized for the
    /// host platform's typical memory budget.
    ///
    /// - iOS, watchOS, tvOS: 16 MiB. These platforms have aggressive jetsam
    ///   limits and tight working sets, especially in extensions or when
    ///   the app is backgrounded mid-upload.
    /// - macOS, visionOS: 50 MiB. Desktop and spatial environments have
    ///   significantly more headroom and can amortize the larger
    ///   in-memory window in exchange for fewer temp-file writes.
    public static var platformDefault: MultipartUploadStrategy {
        #if os(iOS) || os(watchOS) || os(tvOS)
        return .streamingThreshold(bytes: 16 * 1024 * 1024)
        #else
        return .streamingThreshold(bytes: 50 * 1024 * 1024)
        #endif
    }
}


/// Describes a multipart endpoint executed by `DefaultNetworkClient`.
///
/// Multipart endpoints encode their bodies through ``multipartFormData`` and
/// only need ``transport`` to describe how the response is decoded. The
/// default ``transport`` is ``TransportPolicy/multipart(decoder:)``, which
/// configures a JSON response decoder.
///
/// HTTP envelope requirements (method, path, headers, interceptors,
/// status-code acceptance, transport) are inherited from
/// ``EndpointShape``; `MultipartAPIDefinition` adds only the body-strategy
/// surface (`multipartFormData`, `uploadStrategy`).
public protocol MultipartAPIDefinition: EndpointShape {
    var multipartFormData: MultipartFormData { get }

    /// Strategy that decides whether the multipart body is encoded in memory
    /// or streamed to a temp file. Default is
    /// ``MultipartUploadStrategy/platformDefault`` — a memory-aware
    /// ``MultipartUploadStrategy/streamingThreshold(bytes:)`` (16 MiB on
    /// iOS/watchOS/tvOS, 50 MiB on macOS/visionOS) so that large
    /// attachments do not blow up peak memory by default. Endpoints that
    /// always upload small payloads can override with
    /// ``MultipartUploadStrategy/inMemory`` to skip the size check;
    /// endpoints that always upload large payloads can override with
    /// ``MultipartUploadStrategy/alwaysStream``.
    var uploadStrategy: MultipartUploadStrategy { get }
}

// MARK: - APIDefinition default extension

extension APIDefinition where Parameter == EmptyParameter {
    public var parameters: Parameter? { nil }
}

public extension APIDefinition {
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
    var uploadStrategy: MultipartUploadStrategy { .platformDefault }

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
