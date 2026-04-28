import Foundation

/// Task-local context propagated alongside an in-flight network request.
///
/// `NetworkContext` is a minimal carrier for cross-cutting metadata that a
/// caller wants every downstream request to attach without manually
/// threading values through every API call: correlation IDs that pair a
/// request with a downstream service log, distributed-tracing IDs, and
/// arbitrary string baggage that surfaces in interceptors and observers.
///
/// The type is intentionally not wired into ``NetworkConfiguration`` or
/// ``DefaultNetworkClient`` directly. Callers opt in by:
///
/// 1. Adding ``CorrelationIDInterceptor`` (or a custom interceptor that
///    reads ``NetworkContext/current``) to their session-level
///    ``RequestInterceptor`` chain.
/// 2. Wrapping the work that triggers the request in
///    ``NetworkContext/$current``:
///
///    ```swift
///    NetworkContext.$current.withValue(
///        NetworkContext(
///            traceID: traceID,
///            correlationID: correlationID
///        )
///    ) {
///        Task {
///            try await client.request(GetUser(id: id))
///        }
///    }
///    ```
///
/// `Task.local` propagation is the standard Swift Concurrency mechanism
/// for this; the interceptor reads ``NetworkContext/current`` synchronously
/// from inside its `adapt(_:)` body and copies the relevant values onto
/// the outgoing `URLRequest`.
public struct NetworkContext: Sendable {
    /// Distributed-tracing identifier for the calling business operation.
    /// Typically a W3C Trace Context `trace-id` (32 lowercase hex chars).
    public let traceID: String?

    /// Correlation identifier paired with downstream log lines for the
    /// same logical user action. Often a UUID string.
    public let correlationID: String?

    /// Optional free-form key/value metadata. The keys are not coerced to
    /// any standard, so callers and interceptors must agree on conventions.
    public let baggage: [String: String]

    public init(
        traceID: String? = nil,
        correlationID: String? = nil,
        baggage: [String: String] = [:]
    ) {
        self.traceID = traceID
        self.correlationID = correlationID
        self.baggage = baggage
    }

    /// The currently bound context for the executing task. Defaults to an
    /// empty value when no surrounding ``withValue(_:operation:)`` scope is
    /// active.
    @TaskLocal public static var current: NetworkContext = NetworkContext()
}
