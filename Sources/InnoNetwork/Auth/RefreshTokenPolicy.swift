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

    /// Creates a token refresh policy.
    ///
    /// - Parameters:
    ///   - refreshStatusCodes: Status codes that should trigger a refresh
    ///     and one request replay. Defaults to `401`.
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

    private enum RefreshState {
        case idle
        case inFlight(id: UUID, task: Task<String, Error>)
        case cooldown(until: Date, lastError: any Error & Sendable)
    }

    private let policy: RefreshTokenPolicy
    private let now: @Sendable () -> Date
    private var state: RefreshState = .idle
    private var consecutiveFailures: Int = 0

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
        if case .inFlight = state { return true }
        return false
    }

    package func applyCurrentToken(to request: URLRequest) async throws -> URLRequest {
        guard let token = try await policy.currentTokenProvider() else { return request }
        return policy.tokenApplicator(token, request)
    }

    package func refreshAndApply(to request: URLRequest) async throws -> URLRequest {
        try Task.checkCancellation()
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

    package func shouldRefresh(statusCode: Int) -> Bool {
        policy.refreshStatusCodes.contains(statusCode)
    }

    private func refreshedToken() async throws -> String {
        switch state {
        case .cooldown(let until, let lastError):
            if now() < until { throw lastError }
            state = .idle
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
        state = .inFlight(id: id, task: task)
        return try await task.value
    }

    private func refreshDidSucceed(id: UUID) {
        guard case .inFlight(let currentId, _) = state, currentId == id else { return }
        consecutiveFailures = 0
        state = .idle
    }

    private func refreshDidCancel(id: UUID) {
        guard case .inFlight(let currentId, _) = state, currentId == id else { return }
        state = .idle
    }

    private func refreshDidFail(id: UUID, error: any Error & Sendable) {
        guard case .inFlight(let currentId, _) = state, currentId == id else { return }
        consecutiveFailures += 1
        let cooldown = policy.failureCooldown.cooldown(afterConsecutiveFailures: consecutiveFailures)
        if cooldown > 0 {
            state = .cooldown(
                until: now().addingTimeInterval(cooldown),
                lastError: error
            )
        } else {
            state = .idle
        }
    }
}
