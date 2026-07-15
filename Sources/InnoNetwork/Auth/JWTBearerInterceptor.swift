import Foundation

/// Late authentication-header provider that attaches a request-minted JWT
/// through the standard `Authorization: Bearer <token>` header.
///
/// Use this interceptor for the **request-minted** lane only — backends
/// where the JWT claims include the request method/path or otherwise
/// have to be re-signed per call. Session-rotated bearer tokens (the
/// common OAuth2 pattern) are better served by ``RefreshTokenPolicy``,
/// which already coalesces single-flight refresh and replays one
/// in-flight request after a 401.
///
/// The interceptor itself is intentionally minimal: it pulls a token
/// string from a caller-supplied async closure and writes the
/// `Authorization` header. Key material — HS256 secrets, RS256/ES256
/// private keys — never lives inside the interceptor; the closure can
/// hold a reference to a Keychain item, a Secure Enclave handle, or a
/// remote token-mint service. That keeps the interceptor `Sendable`
/// without leaking key material into log dumps or error chains.
///
/// Typical wiring against a Keychain-backed actor:
///
/// ```swift
/// let auth = AuthService(...)
/// let signer = JWTBearerInterceptor { request in
///     try await auth.mintJWT(for: request)
/// }
/// // Attach to the configuration's request interceptors:
/// let config = NetworkConfiguration.advanced(
///     baseURL: baseURL,
///     auth: AuthPack(additionalSigners: [signer])
/// )
/// ```
///
/// The interceptor does **not** mint, encode, or sign the JWT. That work
/// is delegated to the caller because the algorithm matrix
/// (HS256/RS256/ES256/EdDSA) and the claims set are application-specific
/// and outside the scope of a generic networking library.
///
/// Despite its legacy `Interceptor` suffix, this type conforms to
/// ``RequestSigner`` in the unreleased 5.0 preview. The header is produced
/// after ordinary request interceptors and refresh-token adaptation, so the
/// token provider observes the final URL and method. If both a refresh policy
/// and this provider are configured, this later request-minted JWT
/// intentionally wins.
public struct JWTBearerInterceptor: RequestSigner {
    /// Closure that mints the JWT for a given request. Invoked once per
    /// request attempt; rate-limit and cache inside the closure if the
    /// minting cost is non-trivial.
    public let tokenProvider: @Sendable (URLRequest) async throws -> String

    /// Authorization scheme written into the header. Defaults to `Bearer`,
    /// which matches RFC 6750. Override when the backend expects a custom
    /// scheme (e.g. `JWT`, `Token`).
    public let scheme: String

    /// Header into which the token is written. Defaults to `Authorization`.
    /// Override when the backend uses a non-standard header (e.g.
    /// `X-Auth-Token`).
    public let headerName: String

    /// Creates a new JWT bearer interceptor.
    ///
    /// - Parameters:
    ///   - scheme: Authorization scheme. Defaults to `"Bearer"`.
    ///   - headerName: Header to write. Defaults to `"Authorization"`.
    ///   - tokenProvider: Closure that returns the encoded JWT string for
    ///     a given outgoing request. The closure is invoked on every
    ///     attempt; throw to abort the request.
    public init(
        scheme: String = "Bearer",
        headerName: String = "Authorization",
        tokenProvider: @escaping @Sendable (URLRequest) async throws -> String
    ) {
        self.scheme = scheme
        self.headerName = headerName
        self.tokenProvider = tokenProvider
    }

    public func signatureHeaders(
        for request: URLRequest,
        body: RequestBody
    ) async throws -> HTTPHeaders {
        _ = body
        let token = try await tokenProvider(request)
        return HTTPHeaders([
            HTTPHeader(name: headerName, value: "\(scheme) \(token)")
        ])
    }
}
