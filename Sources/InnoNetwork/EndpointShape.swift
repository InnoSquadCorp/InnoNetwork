import Foundation

/// Common request-shape surface shared by ``APIDefinition`` and
/// ``MultipartAPIDefinition``.
///
/// `EndpointShape` is the protocol that captures everything an endpoint
/// describes about its HTTP envelope independent of the body strategy:
/// method, path, headers, observability hooks, status-code acceptance,
/// and the response-side ``TransportPolicy``. Concrete endpoint
/// protocols inherit from `EndpointShape` and add only the body-shape
/// requirements they actually own — `parameters` for
/// ``APIDefinition``, `multipartFormData` and `uploadStrategy` for
/// ``MultipartAPIDefinition``.
///
/// `EndpointShape` is not intended as a direct conformance target for
/// app code; conform to ``APIDefinition`` or ``MultipartAPIDefinition``
/// instead. The protocol is exposed publicly because both
/// ``DefaultNetworkClient`` and the SPI execution pipeline read this
/// surface and external generated clients can document against the
/// same vocabulary.
public protocol EndpointShape: Sendable {
    /// Decoded response type produced by this endpoint.
    ///
    /// The response must be safe to cross concurrency boundaries because the
    /// client may decode and deliver values from background tasks.
    associatedtype APIResponse: Decodable & Sendable

    /// HTTP method used when constructing the `URLRequest`.
    var method: HTTPMethod { get }

    /// Path appended to the client's base URL.
    ///
    /// Values may contain path placeholders already expanded by callers or
    /// generated clients. The executor combines this path with
    /// ``NetworkConfiguration/baseURL`` before request interceptors run.
    var path: String { get }

    /// Headers attached before request interceptors and auth refresh policies
    /// adapt the request. The default implementation returns
    /// ``HTTPHeaders/default``.
    var headers: HTTPHeaders { get }

    /// Logger used by endpoint-owned execution hooks. The default
    /// implementation returns ``DefaultNetworkLogger``.
    var logger: NetworkLogger { get }

    /// Endpoint-level request adapters that run after configuration-level
    /// request interceptors and before auth refresh policies.
    ///
    /// The default implementation returns an empty array.
    var requestInterceptors: [RequestInterceptor] { get }

    /// Endpoint-level response adapters that run before configuration-level
    /// response interceptors and before status-code validation.
    ///
    /// The default implementation returns an empty array.
    var responseInterceptors: [ResponseInterceptor] { get }

    /// Per-endpoint override for the set of acceptable HTTP status codes.
    ///
    /// When `nil`, the executor falls back to
    /// ``NetworkConfiguration/acceptableStatusCodes``.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Single transport-shape entry point describing how the response
    /// is decoded. Concrete endpoint protocols supply method-aware or
    /// body-aware defaults via their own extensions.
    var transport: TransportPolicy<APIResponse> { get }

    /// Per-endpoint override for the request timeout. When non-nil the
    /// value replaces ``NetworkConfiguration/timeout`` on the built
    /// `URLRequest`. Defaults to `nil` so endpoints inherit the client
    /// timeout.
    var timeoutOverride: TimeInterval? { get }

    /// Per-endpoint override for `URLRequest.cachePolicy`. When non-nil
    /// the value replaces ``NetworkConfiguration/cachePolicy`` on the
    /// built `URLRequest`. Defaults to `nil` so endpoints inherit the
    /// client cache policy.
    var cachePolicyOverride: URLRequest.CachePolicy? { get }

    /// Per-endpoint override for request priority. Defaults to `nil` so
    /// endpoints inherit ``NetworkConfiguration/requestPriority``.
    var priorityOverride: RequestPriority? { get }

    /// Per-endpoint override for cellular access. Defaults to `nil`.
    var allowsCellularAccessOverride: Bool? { get }

    /// Per-endpoint override for expensive network access. Defaults to `nil`.
    var allowsExpensiveNetworkAccessOverride: Bool? { get }

    /// Per-endpoint override for constrained network access. Defaults to `nil`.
    var allowsConstrainedNetworkAccessOverride: Bool? { get }
}

// MARK: - Shared default implementations

public extension EndpointShape {
    /// Default headers for endpoints that do not need custom envelope headers.
    var headers: HTTPHeaders { HTTPHeaders.default }

    /// Default logger for endpoints that do not provide a custom logger.
    var logger: NetworkLogger { DefaultNetworkLogger() }

    /// Default empty request-interceptor chain.
    var requestInterceptors: [RequestInterceptor] { [] }

    /// Default empty response-interceptor chain.
    var responseInterceptors: [ResponseInterceptor] { [] }

    /// Default status-code policy, delegating to the client configuration.
    var acceptableStatusCodes: Set<Int>? { nil }

    /// Default timeout override, delegating to the client configuration.
    var timeoutOverride: TimeInterval? { nil }

    /// Default cache policy override, delegating to the client configuration.
    var cachePolicyOverride: URLRequest.CachePolicy? { nil }

    /// Default priority override, delegating to the client configuration.
    var priorityOverride: RequestPriority? { nil }

    /// Default cellular access override, delegating to the client configuration.
    var allowsCellularAccessOverride: Bool? { nil }

    /// Default expensive network access override, delegating to the client configuration.
    var allowsExpensiveNetworkAccessOverride: Bool? { nil }

    /// Default constrained network access override, delegating to the client configuration.
    var allowsConstrainedNetworkAccessOverride: Bool? { nil }
}
