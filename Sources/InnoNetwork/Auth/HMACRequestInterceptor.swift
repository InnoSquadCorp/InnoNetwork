import CryptoKit
import Foundation

/// Signs outgoing requests by computing an HMAC over the exact transport body
/// and returning the resulting signature plus a key identifier as headers.
///
/// This is a **reference implementation** suitable for backends that
/// expect a simple `HMAC(secret, body)` signature header (the most common
/// shape for internal service-to-service auth, webhooks, and lightweight
/// API gateways). Production use against AWS SigV4, Twitter OAuth1, or
/// other canonical-string protocols requires a richer canonicalization
/// step and should be implemented as a dedicated signer on top of the same
/// ``RequestSigner`` contract.
///
/// ## Composition
///
/// ```swift
/// let signer = HMACRequestInterceptor(
///     keyID: "client-42",
///     secret: Data(secretString.utf8)
/// )
///
/// let configuration = NetworkConfiguration.advanced(
///     baseURL: baseURL,
///     auth: AuthPack(additionalSigners: [signer])
/// )
/// ```
///
/// The signer consumes ``RequestBody`` (using incremental reads for files),
/// derives a `Base64`-encoded MAC using the configured ``Algorithm``, and
/// returns both the signature and key id. It runs after all request
/// interceptors and token adaptation on every attempt.
///
/// `URLRequest.httpBodyStream` remains unsupported because it cannot be read
/// without consuming the wire stream. Use a data or file payload instead.
///
/// ## Header defaults
///
/// The default header names (`X-Signature`, `X-Signature-Key-Id`) match a
/// common convention; consumers integrating with backends that expect
/// other names (`X-Hub-Signature-256` for GitHub webhooks, `X-Slack-Signature`
/// for Slack, etc.) should override them at construction.
public struct HMACRequestInterceptor: RequestSigner {
    /// HMAC variants supported by ``HMACRequestInterceptor``.
    ///
    /// The library exposes the SHA-2 family because every CryptoKit
    /// shipping platform supports it and SHA-1 is no longer recommended
    /// for new MAC integrations. Backends that mandate SHA-1 should
    /// implement their own interceptor against `HMAC<Insecure.SHA1>`.
    public enum Algorithm: String, Sendable, CaseIterable {
        case sha256
        case sha384
        case sha512
    }

    private let keyID: String
    private let algorithm: Algorithm
    private let signatureHeaderName: String
    private let keyIDHeaderName: String

    private let key: SymmetricKey

    /// Creates a new HMAC interceptor.
    ///
    /// - Parameters:
    ///   - keyID: Identifier for the key used to compute the signature.
    ///     Emitted in the `keyIDHeaderName` header so the backend can
    ///     resolve the matching secret without rotating clients.
    ///   - secret: Raw key bytes. Whatever encoding the backend uses
    ///     (UTF-8 string, hex-decoded, base64-decoded) must be reversed
    ///     before reaching this initializer; the interceptor treats the
    ///     `Data` as opaque key material.
    ///   - algorithm: HMAC variant. Defaults to ``Algorithm/sha256``,
    ///     which matches the prevailing webhook convention.
    ///   - signatureHeaderName: Header into which the base64-encoded
    ///     MAC is written. Defaults to `X-Signature`.
    ///   - keyIDHeaderName: Header into which `keyID` is written.
    ///     Defaults to `X-Signature-Key-Id`.
    public init(
        keyID: String,
        secret: Data,
        algorithm: Algorithm = .sha256,
        signatureHeaderName: String = "X-Signature",
        keyIDHeaderName: String = "X-Signature-Key-Id"
    ) {
        self.keyID = keyID
        self.algorithm = algorithm
        self.signatureHeaderName = signatureHeaderName
        self.keyIDHeaderName = keyIDHeaderName
        self.key = SymmetricKey(data: secret)
    }

    public func signatureHeaders(
        for request: URLRequest,
        body: RequestBody
    ) async throws -> HTTPHeaders {
        _ = request
        let signature = try HMACRequestInterceptor.signature(for: body, using: key, algorithm: algorithm)
        return HTTPHeaders([
            HTTPHeader(name: signatureHeaderName, value: signature),
            HTTPHeader(name: keyIDHeaderName, value: keyID),
        ])
    }

    static func signature(for body: RequestBody, using key: SymmetricKey, algorithm: Algorithm) throws -> String {
        switch algorithm {
        case .sha256:
            var hmac = HMAC<SHA256>(key: key)
            try body.forEachChunk { hmac.update(data: $0) }
            return Data(hmac.finalize()).base64EncodedString()
        case .sha384:
            var hmac = HMAC<SHA384>(key: key)
            try body.forEachChunk { hmac.update(data: $0) }
            return Data(hmac.finalize()).base64EncodedString()
        case .sha512:
            var hmac = HMAC<SHA512>(key: key)
            try body.forEachChunk { hmac.update(data: $0) }
            return Data(hmac.finalize()).base64EncodedString()
        }
    }
}
