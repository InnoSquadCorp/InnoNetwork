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

    /// Creates a token refresh policy.
    ///
    /// - Parameters:
    ///   - refreshStatusCodes: Status codes that should trigger a refresh
    ///     and one request replay. Defaults to `401`.
    ///   - currentToken: Returns the currently cached token, or `nil` when
    ///     the request should be sent without an authorization header.
    ///   - refreshToken: Refreshes and returns a new token. Concurrent
    ///     refreshes are collapsed into one task by the client.
    ///   - applyToken: Applies a token to a request. Defaults to a Bearer
    ///     `Authorization` header.
    public init(
        refreshStatusCodes: Set<Int> = [401],
        currentToken: @escaping @Sendable () async throws -> String?,
        refreshToken: @escaping @Sendable () async throws -> String,
        applyToken: @escaping @Sendable (String, URLRequest) -> URLRequest = { token, request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    ) {
        self.refreshStatusCodes = refreshStatusCodes
        self.currentTokenProvider = currentToken
        self.refreshTokenProvider = refreshToken
        self.tokenApplicator = applyToken
    }
}


package actor RefreshTokenCoordinator {
    private struct InFlightRefresh {
        let id: UUID
        let task: Task<String, Error>
    }

    private let policy: RefreshTokenPolicy
    private var inFlight: InFlightRefresh?

    package init(policy: RefreshTokenPolicy) {
        self.policy = policy
    }

    /// Whether a refresh task is currently in flight.
    ///
    /// Reads are point-in-time and not synchronized with subsequent
    /// dedup-key construction; callers must treat the value as a
    /// best-effort hint. The intended consumer is
    /// ``RequestExecutor`` segregating coalescer lanes during a refresh
    /// window so a stale 401 result cannot leak across callers when
    /// `Authorization` is excluded from the dedup key.
    package var isRefreshInProgress: Bool { inFlight != nil }

    package func applyCurrentToken(to request: URLRequest) async throws -> URLRequest {
        guard let token = try await policy.currentTokenProvider() else { return request }
        return policy.tokenApplicator(token, request)
    }

    package func refreshAndApply(to request: URLRequest) async throws -> URLRequest {
        let token = try await refreshedToken()
        try Task.checkCancellation()
        // Strip the prior `Authorization` header before reapplying so custom
        // applicators that use `addValue` do not stack tokens on a replay.
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        return policy.tokenApplicator(token, sanitized)
    }

    package func shouldRefresh(statusCode: Int) -> Bool {
        policy.refreshStatusCodes.contains(statusCode)
    }

    private func refreshedToken() async throws -> String {
        if let inFlight {
            do {
                return try await inFlight.task.value
            } catch {
                // The shared task already finished (failure). Clear it inside
                // the actor so the next caller starts a fresh refresh instead
                // of replaying the cached failure.
                if self.inFlight?.id == inFlight.id { self.inFlight = nil }
                throw error
            }
        }

        let refreshTokenProvider = policy.refreshTokenProvider
        let id = UUID()
        let task = Task.detached(priority: Task.currentPriority) {
            try await refreshTokenProvider()
        }
        inFlight = InFlightRefresh(id: id, task: task)
        do {
            let token = try await task.value
            if self.inFlight?.id == id { self.inFlight = nil }
            return token
        } catch {
            if self.inFlight?.id == id { self.inFlight = nil }
            throw error
        }
    }
}
