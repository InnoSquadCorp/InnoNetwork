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
    associatedtype APIResponse: Decodable & Sendable

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

    /// Single transport-shape entry point describing how the response
    /// is decoded. Concrete endpoint protocols supply method-aware or
    /// body-aware defaults via their own extensions.
    var transport: TransportPolicy<APIResponse> { get }
}

// MARK: - Shared default implementations

public extension EndpointShape {
    var headers: HTTPHeaders { HTTPHeaders.default }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }

    var acceptableStatusCodes: Set<Int>? { nil }
}
