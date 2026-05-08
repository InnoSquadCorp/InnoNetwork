import CryptoKit
import Foundation

/// Signs outgoing requests by computing an HMAC over the request body and
/// attaching the resulting signature plus a key identifier as headers.
///
/// This is a **reference implementation** suitable for backends that
/// expect a simple `HMAC(secret, body)` signature header (the most common
/// shape for internal service-to-service auth, webhooks, and lightweight
/// API gateways). Production use against AWS SigV4, Twitter OAuth1, or
/// other canonical-string protocols requires a richer canonicalization
/// step and should be implemented as a dedicated interceptor on top of
/// the same ``RequestInterceptor`` contract.
///
/// ## Composition
///
/// ```swift
/// let signer = HMACRequestInterceptor(
///     keyID: "client-42",
///     secret: Data(secretString.utf8)
/// )
///
/// let configuration = NetworkConfiguration.advanced(baseURL: baseURL) { builder in
///     builder.requestInterceptors.append(signer)
/// }
/// ```
///
/// The interceptor reads ``URLRequest/httpBody`` (which may be `nil` for
/// bodyless requests, in which case the signature is computed over an
/// empty payload), derives a `Base64`-encoded MAC using the configured
/// ``Algorithm``, and writes both the signature and key id into the
/// supplied header names. Per the
/// ``RequestInterceptor`` documentation, this runs once per attempt, so
/// retries pick up a fresh signature derived from any body mutations
/// upstream interceptors may have introduced.
///
/// ## Streaming bodies
///
/// `URLRequest.httpBodyStream` is unsupported: hashing a stream would
/// either require buffering the entire payload (defeating the streaming
/// contract) or rebuilding the stream from the consumed bytes. When the
/// request carries a streaming body the interceptor throws
/// ``NetworkError/configuration(reason:)`` with
/// ``NetworkConfigurationFailureReason/invalidRequest(_:)`` so the failure
/// is surfaced before the bytes hit the wire. Use a custom signing
/// interceptor that integrates with the upload-side streaming hook in these
/// cases.
///
/// ## Header defaults
///
/// The default header names (`X-Signature`, `X-Signature-Key-Id`) match a
/// common convention; consumers integrating with backends that expect
/// other names (`X-Hub-Signature-256` for GitHub webhooks, `X-Slack-Signature`
/// for Slack, etc.) should override them at construction.
public struct HMACRequestInterceptor: RequestInterceptor {
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

    public let keyID: String
    public let algorithm: Algorithm
    public let signatureHeaderName: String
    public let keyIDHeaderName: String

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

    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        if urlRequest.httpBodyStream != nil {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "HMACRequestInterceptor cannot sign streaming bodies; provide an in-memory httpBody or implement a custom interceptor."
                ))
        }

        var mutable = urlRequest
        let body = urlRequest.httpBody ?? Data()
        let signature = HMACRequestInterceptor.signature(for: body, using: key, algorithm: algorithm)
        mutable.setValue(signature, forHTTPHeaderField: signatureHeaderName)
        mutable.setValue(keyID, forHTTPHeaderField: keyIDHeaderName)
        return mutable
    }

    static func signature(for body: Data, using key: SymmetricKey, algorithm: Algorithm) -> String {
        switch algorithm {
        case .sha256:
            let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
            return Data(mac).base64EncodedString()
        case .sha384:
            let mac = HMAC<SHA384>.authenticationCode(for: body, using: key)
            return Data(mac).base64EncodedString()
        case .sha512:
            let mac = HMAC<SHA512>.authenticationCode(for: body, using: key)
            return Data(mac).base64EncodedString()
        }
    }
}
