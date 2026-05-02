import Foundation

/// Immutable input passed to a custom request execution policy.
public struct RequestExecutionInput: Sendable {
    public let request: URLRequest
    public let requestID: UUID
    public let retryIndex: Int

    public init(request: URLRequest, requestID: UUID, retryIndex: Int) {
        self.request = request
        self.requestID = requestID
        self.retryIndex = retryIndex
    }
}

/// Context shared with custom execution policies for one transport attempt.
public struct RequestExecutionContext: Sendable {
    public let requestID: UUID
    public let retryIndex: Int
    public let metricsReporter: (any NetworkMetricsReporting)?
    public let trustPolicy: TrustPolicy
    public let eventObservers: [any NetworkEventObserving]

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

    public init(_ executeRequest: @escaping @Sendable (URLRequest) async throws -> Response) {
        self.executeRequest = executeRequest
    }

    public func execute(_ request: URLRequest) async throws -> Response {
        try await executeRequest(request)
    }
}

/// Public extension point for wrapping a request transport attempt.
public protocol RequestExecutionPolicy: Sendable {
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
