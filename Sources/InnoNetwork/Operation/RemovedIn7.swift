import Foundation

// Names removed in 7.0.
//
// 7.0 removed these declarations without a deprecation release. They remain
// here only as `unavailable` declarations so that code written against 6.x
// fails to compile with a message that names the replacement, instead of a
// bare "cannot find type in scope". None of them can be used at runtime.
// See `docs/Migration-7.0.0.md`.

/// Removed in 7.0. Operation handles are created on the client itself.
@available(
    *, unavailable,
    message:
        "OperationNetworkClient was removed in 7.0. Call start(_:replaySafety:deadline:) on the client itself, for example client.start(request)."
)
public struct OperationNetworkClient<Base: Sendable>: Sendable {
    @available(
        *, unavailable,
        message:
            "OperationNetworkClient was removed in 7.0. Call start(_:replaySafety:deadline:) on the client itself, for example client.start(request)."
    )
    public init(client: Base) {}
}

/// Removed in 7.0. ``NetworkConfiguration`` is the only configuration type.
@available(*, unavailable, renamed: "NetworkConfiguration")
public typealias NetworkClientConfiguration = NetworkConfiguration

/// Removed in 7.0. ``NetworkError`` is the only thrown type; its payload-free
/// form is ``NetworkErrorSummary``.
@available(
    *, unavailable,
    message:
        "NetworkFailure was removed in 7.0. Operations throw NetworkError; use error.summary for the payload-free value (NetworkErrorSummary)."
)
public typealias NetworkFailure = NetworkErrorSummary

/// Removed in 7.0. Use ``NetworkErrorCategory``.
@available(*, unavailable, renamed: "NetworkErrorCategory")
public typealias NetworkFailureKind = NetworkErrorCategory

extension NetworkConfiguration {
    /// Removed in 7.0. Use ``safeDefaults(baseURL:)``.
    @available(*, unavailable, renamed: "safeDefaults(baseURL:)")
    public static func secure(baseURL: URL) -> NetworkConfiguration {
        safeDefaults(baseURL: baseURL)
    }

    /// Removed in 7.0. Use
    /// ``advanced(baseURL:resilience:auth:observability:cache:transport:)``;
    /// the `authentication:` label is `auth:` there.
    @available(
        *, unavailable,
        renamed: "advanced(baseURL:resilience:auth:observability:cache:transport:)"
    )
    public static func production(
        baseURL: URL,
        resilience: ResiliencePack = ResiliencePack(),
        authentication: AuthPack = AuthPack(),
        observability: ObservabilityPack = ObservabilityPack(),
        cache: CachePack = CachePack(),
        transport: TransportPack = TransportPack()
    ) -> NetworkConfiguration {
        advanced(
            baseURL: baseURL,
            resilience: resilience,
            auth: authentication,
            observability: observability,
            cache: cache,
            transport: transport
        )
    }
}
