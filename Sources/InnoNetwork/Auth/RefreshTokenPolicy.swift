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

    package func applyCurrentToken(to request: URLRequest) async throws -> URLRequest {
        guard let token = try await policy.currentTokenProvider() else { return request }
        return policy.tokenApplicator(token, request)
    }

    package func refreshAndApply(to request: URLRequest) async throws -> URLRequest {
        let token = try await refreshedToken()
        try Task.checkCancellation()
        return policy.tokenApplicator(token, request)
    }

    package func shouldRefresh(statusCode: Int) -> Bool {
        policy.refreshStatusCodes.contains(statusCode)
    }

    private func refreshedToken() async throws -> String {
        if let inFlight {
            return try await inFlight.task.value
        }

        let refreshTokenProvider = policy.refreshTokenProvider
        let id = UUID()
        let task = Task.detached(priority: Task.currentPriority) {
            try await refreshTokenProvider()
        }
        inFlight = InFlightRefresh(id: id, task: task)
        Task.detached {
            _ = await task.result
            await self.clearInFlight(id: id)
        }
        return try await task.value
    }

    private func clearInFlight(id: UUID) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }
}
