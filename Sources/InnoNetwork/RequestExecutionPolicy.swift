import Foundation

/// Immutable input passed to a custom request execution policy.
public struct RequestExecutionInput: Sendable {
    /// The request as adapted by the executor immediately before this policy
    /// runs. A policy may produce a modified copy and pass it to ``next`` to
    /// influence the rest of the chain.
    public let request: URLRequest
    /// Stable identifier shared with metrics, events, and downstream policies
    /// for the entire request — including retries.
    public let requestID: UUID
    /// Zero for the first attempt, incrementing once per retry of the same
    /// `requestID`.
    public let retryIndex: Int

    /// Construct an execution input. The executor populates this; callers do
    /// not need to construct it directly outside of tests.
    public init(request: URLRequest, requestID: UUID, retryIndex: Int) {
        self.request = request
        self.requestID = requestID
        self.retryIndex = retryIndex
    }
}

/// Context shared with custom execution policies for one transport attempt.
public struct RequestExecutionContext: Sendable {
    /// Stable identifier shared with the corresponding ``RequestExecutionInput``.
    public let requestID: UUID
    /// Zero for the first attempt, incrementing once per retry.
    public let retryIndex: Int
    /// Optional metrics reporter the policy may use for custom signals.
    public let metricsReporter: (any NetworkMetricsReporting)?
    /// The trust policy in effect for the host; informational so policies can
    /// branch on `.system` vs. pinned trust.
    public let trustPolicy: TrustPolicy
    /// Event observers that should receive any custom events the policy emits.
    public let eventObservers: [any NetworkEventObserving]

    /// Construct an execution context. The executor populates this; callers do
    /// not need to construct it directly outside of tests.
    public init(
        requestID: UUID,
        retryIndex: Int,
        metricsReporter: (any NetworkMetricsReporting)?,
        trustPolicy: TrustPolicy,
        eventObservers: [any NetworkEventObserving]
    ) {
        self.requestID = requestID
        self.retryIndex = retryIndex
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
    }
}

/// Calls the next policy in the chain, or the built-in transport when the
/// current policy is the innermost policy.
public struct RequestExecutionNext: Sendable {
    private let executeRequest: @Sendable (URLRequest) async throws -> Response

    /// Wrap a continuation closure as a `RequestExecutionNext`. The executor
    /// constructs this; tests can construct one directly when exercising a
    /// single policy in isolation.
    public init(_ executeRequest: @escaping @Sendable (URLRequest) async throws -> Response) {
        self.executeRequest = executeRequest
    }

    /// Forward `request` to the rest of the chain (or the transport if this is
    /// the innermost policy) and return the resulting response.
    ///
    /// Calling convention:
    ///
    /// - A policy may call `execute(_:)` zero or more times. Calling it more
    ///   than once produces multiple transport attempts; the executor publishes
    ///   one ``NetworkEvent/responseReceived`` for each successful call.
    /// - A policy that returns a synthetic response without calling `execute`
    ///   bypasses the transport entirely. The executor will not record a
    ///   `responseReceived` event for that path.
    /// - The request passed to `execute` becomes the `URLRequest` consumed by
    ///   the next policy. Use this to layer headers, swap URLs, or substitute
    ///   bodies for the rest of the chain.
    public func execute(_ request: URLRequest) async throws -> Response {
        try await executeRequest(request)
    }
}

/// Public extension point for wrapping a request transport attempt.
public protocol RequestExecutionPolicy: Sendable {
    /// Invoke the policy for a single transport attempt.
    ///
    /// Implementations should call `next.execute(_:)` exactly once for the
    /// common case of forwarding to the rest of the chain. They may call it
    /// multiple times to retry within the same attempt, or skip the call to
    /// short-circuit with a synthetic response. See
    /// ``RequestExecutionNext/execute(_:)`` for the full calling contract.
    func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response
}

/// Type-erased custom execution policy.
public struct AnyRequestExecutionPolicy: RequestExecutionPolicy {
    private let executePolicy:
        @Sendable (
            RequestExecutionInput,
            RequestExecutionContext,
            RequestExecutionNext
        ) async throws -> Response

    public init<P: RequestExecutionPolicy>(_ policy: P) {
        self.executePolicy = policy.execute(input:context:next:)
    }

    public init(
        _ executePolicy:
            @escaping @Sendable (
                RequestExecutionInput,
                RequestExecutionContext,
                RequestExecutionNext
            ) async throws -> Response
    ) {
        self.executePolicy = executePolicy
    }

    public func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        try await executePolicy(input, context, next)
    }
}
