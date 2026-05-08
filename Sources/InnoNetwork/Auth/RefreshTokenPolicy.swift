import Foundation

/// Opt-in bearer-token refresh policy used by ``DefaultNetworkClient``.
///
/// The policy keeps storage decisions outside the library. Callers provide
/// closures for reading the current token and refreshing it; InnoNetwork owns
/// only the single-flight coordination and one-time replay after configured
/// authentication status codes.
public struct RefreshTokenPolicy: Sendable {
    package let currentTokenProvider: @Sendable () async throws -> String?
    package let refreshTokenProvider: @Sendable () async throws -> String
    package let tokenApplicator: @Sendable (String, URLRequest) -> URLRequest
    package let refreshStatusCodes: Set<Int>
    package let failureCooldown: RefreshFailureCooldown
    package let appliesToRequest: @Sendable (URLRequest) -> Bool

    /// Creates a token refresh policy.
    ///
    /// - Parameters:
    ///   - refreshStatusCodes: Status codes that should trigger a refresh
    ///     and one request replay. Defaults to `401`.
    ///   - appliesTo: Returns whether this policy should attach tokens and
    ///     refresh for a request. Defaults to every request.
    ///   - failureCooldown: Throttle policy used after a refresh failure to
    ///     suppress thundering-herd retries against a known-bad refresh
    ///     token. Default is exponential backoff (1s base, 30s cap).
    ///   - currentToken: Returns the currently cached token, or `nil` when
    ///     the request should be sent without an authorization header.
    ///   - refreshToken: Refreshes and returns a new token. Concurrent
    ///     refreshes are collapsed into one task by the client.
    ///   - applyToken: Applies a token to a request. Defaults to a Bearer
    ///     `Authorization` header.
    public init(
        refreshStatusCodes: Set<Int> = [401],
        appliesTo: @escaping @Sendable (URLRequest) -> Bool = { _ in true },
        failureCooldown: RefreshFailureCooldown = .exponentialBackoff(base: 1.0, max: 30.0),
        currentToken: @escaping @Sendable () async throws -> String?,
        refreshToken: @escaping @Sendable () async throws -> String,
        applyToken: @escaping @Sendable (String, URLRequest) -> URLRequest = { token, request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    ) {
        self.refreshStatusCodes = refreshStatusCodes
        self.failureCooldown = failureCooldown
        self.appliesToRequest = appliesTo
        self.currentTokenProvider = currentToken
        self.refreshTokenProvider = refreshToken
        self.tokenApplicator = applyToken
    }
}


/// Throttle policy applied after a refresh failure. Suppresses retries
/// against a refresh token that the IdP just rejected so a flapping
/// upstream auth service does not turn into a request stampede.
public struct RefreshFailureCooldown: Sendable {
    package let base: TimeInterval
    package let cap: TimeInterval

    /// `cooldown(after:)` returns `base * 2^(failures-1)` clamped at `cap`.
    /// `failures == 0` returns zero — no cooldown until the *first* failure
    /// has occurred.
    public static func exponentialBackoff(base: TimeInterval, max cap: TimeInterval) -> RefreshFailureCooldown {
        let normalizedBase = max(0, base)
        let normalizedCap = max(normalizedBase, cap)
        return RefreshFailureCooldown(base: normalizedBase, cap: normalizedCap)
    }

    /// Disables cooldown entirely; every failure is immediately retryable.
    public static var disabled: RefreshFailureCooldown {
        RefreshFailureCooldown(base: 0, cap: 0)
    }

    func cooldown(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0, base > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 30))
        let raw = base * pow(2.0, exponent)
        return min(max(raw, base), cap)
    }
}


package actor RefreshTokenCoordinator {
    private let policy: RefreshTokenPolicy
    private let now: @Sendable () -> Date
    private var state: RefreshLifecycleState = .initial

    package init(
        policy: RefreshTokenPolicy,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policy = policy
        self.now = now
    }

    /// Whether a refresh task is currently in flight.
    ///
    /// Reads are point-in-time. The intended consumer is
    /// ``RequestExecutor`` segregating coalescer lanes during a refresh
    /// window so a stale 401 result cannot leak across callers when
    /// `Authorization` is excluded from the dedup key.
    package var isRefreshInProgress: Bool {
        state.isRefreshInProgress
    }

    package func applyCurrentToken(to request: URLRequest) async throws -> URLRequest {
        guard policy.appliesToRequest(request) else { return request }
        guard let token = try await policy.currentTokenProvider() else { return request }
        return policy.tokenApplicator(token, request)
    }

    package func refreshAndApply(to request: URLRequest) async throws -> URLRequest {
        try Task.checkCancellation()
        guard policy.appliesToRequest(request) else { return request }
        let token = try await refreshedToken()
        try Task.checkCancellation()
        // Strip every existing `Authorization` header — case-insensitively —
        // before reapplying so custom applicators that use `addValue` do not
        // stack tokens on a replay, and so a manually-set `authorization`
        // (lowercase) header on the original request is not retained
        // alongside the new credential.
        var sanitized = request
        if let headers = sanitized.allHTTPHeaderFields {
            for key in headers.keys where key.caseInsensitiveCompare("Authorization") == .orderedSame {
                sanitized.setValue(nil, forHTTPHeaderField: key)
            }
        }
        return policy.tokenApplicator(token, sanitized)
    }

    package func shouldRefresh(statusCode: Int, request: URLRequest) -> Bool {
        policy.appliesToRequest(request) && policy.refreshStatusCodes.contains(statusCode)
    }

    private func refreshedToken() async throws -> String {
        state =
            RefreshLifecycleReducer.reduce(
                state: state,
                event: .expireCooldownIfNeeded,
                context: lifecycleContext()
            ).state

        switch state.phase {
        case .cooldown(let until, let lastError):
            if now() < until { throw lastError }
        case .inFlight(_, let task):
            return try await task.value
        case .idle:
            break
        }

        let refreshTokenProvider = policy.refreshTokenProvider
        let id = UUID()
        // State transitions are driven by the detached task's own completion
        // (success/failure/cancel) rather than by the awaiter's catch arms.
        // If the *caller* of `refreshedToken()` is cancelled while awaiting
        // `task.value`, the detached task keeps running, so resetting state
        // here would let a follow-up caller launch a duplicate refresh.
        // Routing the transition through the task itself preserves
        // single-flight even under aggressive caller cancellation.
        //
        // No explicit priority: `Task.currentPriority` previously hard-coded
        // the actor's caller priority into the detached task, which inverted
        // priority when a low-priority caller forced a high-priority refresh
        // to wait. Falling back to the runtime default lets the cooperative
        // pool reorder the refresh under the prevailing priority.
        let task = Task.detached { [weak self] () async throws -> String in
            do {
                let token = try await refreshTokenProvider()
                await self?.refreshDidSucceed(id: id)
                return token
            } catch is CancellationError {
                await self?.refreshDidCancel(id: id)
                throw CancellationError()
            } catch {
                await self?.refreshDidFail(id: id, error: error)
                throw error
            }
        }
        state =
            RefreshLifecycleReducer.reduce(
                state: state,
                event: .start(id: id, task: task),
                context: lifecycleContext()
            ).state
        return try await task.value
    }

    private func refreshDidSucceed(id: UUID) {
        state =
            RefreshLifecycleReducer.reduce(
                state: state,
                event: .succeed(id: id),
                context: lifecycleContext()
            ).state
    }

    private func refreshDidCancel(id: UUID) {
        state =
            RefreshLifecycleReducer.reduce(
                state: state,
                event: .cancel(id: id),
                context: lifecycleContext()
            ).state
    }

    private func refreshDidFail(id: UUID, error: any Error & Sendable) {
        state =
            RefreshLifecycleReducer.reduce(
                state: state,
                event: .fail(id: id, error: error),
                context: lifecycleContext()
            ).state
    }

    private func lifecycleContext() -> RefreshLifecycleContext {
        RefreshLifecycleContext(now: now(), failureCooldown: policy.failureCooldown)
    }
}


package struct RefreshLifecycleState: Sendable {
    package var phase: RefreshLifecyclePhase
    package var consecutiveFailures: Int

    package static var initial: Self {
        RefreshLifecycleState(phase: .idle, consecutiveFailures: 0)
    }

    package var isRefreshInProgress: Bool {
        if case .inFlight = phase { return true }
        return false
    }
}


package enum RefreshLifecyclePhase: Sendable {
    case idle
    case inFlight(id: UUID, task: Task<String, Error>)
    case cooldown(until: Date, lastError: any Error & Sendable)
}


package enum RefreshLifecycleEvent: Sendable {
    case expireCooldownIfNeeded
    case start(id: UUID, task: Task<String, Error>)
    case succeed(id: UUID)
    case cancel(id: UUID)
    case fail(id: UUID, error: any Error & Sendable)
}


package struct RefreshLifecycleContext: Sendable {
    package let now: Date
    package let failureCooldown: RefreshFailureCooldown

    package init(now: Date, failureCooldown: RefreshFailureCooldown) {
        self.now = now
        self.failureCooldown = failureCooldown
    }
}


package enum RefreshLifecycleEffect: Sendable, Equatable {
    case ignoreStaleCompletion
}


package enum RefreshLifecycleReducer: StateReducer {
    package static func reduce(
        state: RefreshLifecycleState,
        event: RefreshLifecycleEvent,
        context: RefreshLifecycleContext
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        switch event {
        case .expireCooldownIfNeeded:
            return expireCooldownIfNeeded(state: state, now: context.now)
        case .start(let id, let task):
            return start(state: state, id: id, task: task)
        case .succeed(let id):
            return complete(state: state, id: id, result: .success(()), context: context)
        case .cancel(let id):
            return cancel(state: state, id: id)
        case .fail(let id, let error):
            return complete(state: state, id: id, result: .failure(error), context: context)
        }
    }

    private static func expireCooldownIfNeeded(
        state: RefreshLifecycleState,
        now: Date
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .cooldown(let until, _) = state.phase, now >= until else {
            return StateReduction(state: state)
        }
        return StateReduction(
            state: RefreshLifecycleState(
                phase: .idle,
                consecutiveFailures: state.consecutiveFailures
            )
        )
    }

    private static func start(
        state: RefreshLifecycleState,
        id: UUID,
        task: Task<String, Error>
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .idle = state.phase else { return StateReduction(state: state) }
        return StateReduction(
            state: RefreshLifecycleState(
                phase: .inFlight(id: id, task: task),
                consecutiveFailures: state.consecutiveFailures
            )
        )
    }

    private static func cancel(
        state: RefreshLifecycleState,
        id: UUID
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .inFlight(let currentId, _) = state.phase, currentId == id else {
            return StateReduction(state: state, effects: [.ignoreStaleCompletion])
        }
        return StateReduction(
            state: RefreshLifecycleState(
                phase: .idle,
                consecutiveFailures: state.consecutiveFailures
            )
        )
    }

    private static func complete(
        state: RefreshLifecycleState,
        id: UUID,
        result: Result<Void, any Error & Sendable>,
        context: RefreshLifecycleContext
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .inFlight(let currentId, _) = state.phase, currentId == id else {
            return StateReduction(state: state, effects: [.ignoreStaleCompletion])
        }

        switch result {
        case .success:
            return StateReduction(state: .initial)
        case .failure(let error):
            let failures = state.consecutiveFailures + 1
            let cooldown = context.failureCooldown.cooldown(afterConsecutiveFailures: failures)
            let phase: RefreshLifecyclePhase =
                cooldown > 0
                ? .cooldown(until: context.now.addingTimeInterval(cooldown), lastError: error)
                : .idle
            return StateReduction(
                state: RefreshLifecycleState(
                    phase: phase,
                    consecutiveFailures: failures
                )
            )
        }
    }
}
