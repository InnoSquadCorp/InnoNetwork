import Foundation


/// Controls how `DefaultNetworkClient` resolves a stubbed response declared on
/// an ``APIDefinition``.
///
/// Stubbing is opt-in: the default ``StubBehavior/never`` value preserves the
/// pre-stub behaviour, so existing endpoints are not affected. Endpoints that
/// declare a non-`nil` ``APIDefinition/sampleResponse`` and a stub behaviour
/// other than ``StubBehavior/never`` short-circuit the network pipeline and
/// return the stub directly.
///
/// Typical use sites:
///
/// - SwiftUI previews that want a deterministic response without spinning up
///   a real server or a `URLProtocol` mock.
/// - Unit tests that prefer an inline stub to a session-level test double.
/// - Developer builds that simulate slow or flaky endpoints by combining
///   ``StubBehavior/delayed(seconds:)`` with a fixed payload.
public enum StubBehavior: Sendable, Equatable {
    /// Disable stubbing. The client executes the request through the real
    /// transport. This is the default.
    case never

    /// Resolve the stub immediately, without simulating any latency. The
    /// caller still receives an `async` value, but the suspension point is
    /// instantaneous.
    case immediate

    /// Resolve the stub after sleeping the supplied duration. Use this to
    /// approximate real-world latency in previews or to surface time-based
    /// races in higher-level code (loading indicators, debouncers, etc.).
    case delayed(seconds: TimeInterval)
}
