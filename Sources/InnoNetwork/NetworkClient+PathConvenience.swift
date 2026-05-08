import Foundation

extension NetworkClient {
    /// Convenience overload that builds a default ``EndpointBuilder`` on the fly
    /// so the response type can be inferred from the call-site annotation.
    ///
    /// ```swift
    /// let user: User = try await client.request("/users/\(id)")
    /// let token: AuthResponse = try await client.request(
    ///     "/login",
    ///     method: .post
    /// )
    /// ```
    ///
    /// The endpoint is materialized with ``PublicAuthScope`` and the default
    /// ``TransportPolicy`` for the chosen method (`.query()` for GET,
    /// `.json()` otherwise) — the same defaults `EndpointBuilder` would
    /// pick for the equivalent builder chain. Endpoints that need
    /// authenticated scopes, custom headers, body parameters, or
    /// per-endpoint interceptors should keep using ``EndpointBuilder``
    /// builders or a hand-written ``APIDefinition``.
    ///
    /// - Parameters:
    ///   - path: The path component appended to the configured base URL.
    ///   - method: HTTP method to dispatch. Defaults to `.get`.
    ///   - tag: Optional ``CancellationTag`` for grouped cancellation; pass
    ///     `nil` (the default) for ungrouped requests.
    /// - Returns: The decoded response inferred from `T`.
    /// - Throws: A ``NetworkError`` or another execution error produced while
    ///   encoding, sending, validating, or decoding the request.
    public func request<T: Decodable & Sendable>(
        _ path: String,
        method: HTTPMethod = .get,
        tag: CancellationTag? = nil
    ) async throws -> T {
        try await self.request(
            EndpointBuilder<T, PublicAuthScope>(method: method, path: path),
            tag: tag
        )
    }
}
