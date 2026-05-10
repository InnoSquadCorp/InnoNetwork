# Request Signing

Authenticate requests with a body-derived signature instead of (or in
addition to) a Bearer token. Covers the
``HMACRequestInterceptor`` reference implementation and the pattern
for layering richer canonicalization protocols on top of the same
``RequestInterceptor`` contract.

## Overview

Some backends authenticate by computing an HMAC over the request body
with a shared secret instead of issuing a session token: webhook
delivery from Stripe / GitHub / Slack, internal RPC behind an API
gateway, partner integrations where rotating session tokens is
expensive. ``RefreshTokenPolicy`` covers OAuth2 Bearer tokens, but
the body-signed lane is structurally different — every request needs
to be re-signed because the signature depends on the body bytes — so
it ships as a regular ``RequestInterceptor``.

## Choosing an interceptor shape

| Backend convention | Recommendation |
| --- | --- |
| `HMAC-SHA256(secret, body)` carried in `X-Signature` plus a key id | Use ``HMACRequestInterceptor`` directly. |
| `HMAC-SHA256(secret, body)` with custom header names (e.g. GitHub `X-Hub-Signature-256`) | Use ``HMACRequestInterceptor`` and override `signatureHeaderName` / `keyIDHeaderName`. |
| Canonical-string signing (AWS SigV4, Twitter OAuth1, Azure SAS) | Implement a custom ``RequestInterceptor`` that builds the canonical request and reuses CryptoKit primitives. |
| Body hash + timestamp + nonce, signed together | Custom interceptor; see "Building a custom signer" below. |
| Streaming (chunk-encoded) request bodies | Custom interceptor with access to the upload pipeline; ``HMACRequestInterceptor`` rejects streaming bodies by design. |

## Wiring `HMACRequestInterceptor`

Register the interceptor on ``NetworkConfiguration`` like any other
``RequestInterceptor``:

```swift
import InnoNetwork

let signer = HMACRequestInterceptor(
    keyID: "client-42",
    secret: Data(secretString.utf8),
    algorithm: .sha256
)

let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    auth: AuthPack(additionalSigners: [signer])
)

let client = DefaultNetworkClient(configuration: configuration)
```

The signer runs once per request attempt (per the
``RequestInterceptor`` documentation), so retries pick up a fresh
signature. Pair it with ``RefreshTokenPolicy`` when the backend
expects both — the order in `requestInterceptors` is the wire order,
and `RefreshTokenPolicy` runs as the last layer regardless, so the
HMAC header is computed over the body before the bearer token is
attached.

## Building a custom signer

Most production protocols want more than `HMAC(secret, body)`:
timestamps, nonces, scoping the signature to method and URL,
versioning the algorithm. The library's contract is intentionally
narrow so consumers can extend it without forking. The skeleton:

```swift
import CryptoKit
import Foundation
import InnoNetwork

struct CanonicalSigner: RequestInterceptor {
    let keyID: String
    let secret: SymmetricKey
    /// Inject a clock closure so tests can pin the timestamp.
    /// Production callers leave the default `{ Date() }`.
    let now: @Sendable () -> Date

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        guard let url = urlRequest.url else {
            throw NetworkError.configuration(reason: .invalidRequest("Missing URL for signing"))
        }
        if urlRequest.httpBodyStream != nil {
            throw NetworkError.configuration(
                reason: .invalidRequest("Streaming bodies require a streaming-aware signer")
            )
        }

        let timestamp = String(Int(now().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let body = urlRequest.httpBody ?? Data()
        let bodyHash = SHA256.hash(data: body)
        let canonical = [
            urlRequest.httpMethod ?? "GET",
            url.path,
            url.query ?? "",
            timestamp,
            nonce,
            Data(bodyHash).base64EncodedString()
        ].joined(separator: "\n")

        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: secret
        )

        var signed = urlRequest
        signed.setValue(keyID, forHTTPHeaderField: "X-Key-Id")
        signed.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        signed.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        signed.setValue(
            Data(mac).base64EncodedString(),
            forHTTPHeaderField: "X-Signature"
        )
        return signed
    }
}
```

`adapt(_:)` runs once per attempt, so every retry produces a fresh
`timestamp` / `nonce` pair, side-stepping replay protection on the
backend.

## Streaming uploads

`HMACRequestInterceptor` rejects requests whose body arrives via
`httpBodyStream` because hashing a stream forces a buffer-or-replay
choice that has to be explicit. If you control the upload path,
prefer one of the following:

1. Hash the bytes during multipart construction (before they become
   a stream) and inject the digest yourself, then sign the digest
   with a custom interceptor that reads the supplied header instead
   of recomputing.
2. Move the signature out of the request body altogether — sign a
   manifest of upload metadata (object key, content length, content
   type, expiry) and let the upload itself proceed unsigned, the way
   AWS S3 presigned PUTs work.
3. Use a chunk-signed protocol (SigV4 streaming) and ship a
   protocol-specific interceptor; the shared
   `RequestInterceptor` surface stays the same.

## AWS SigV4 (built-in reference signer)

``AWSSigV4Interceptor`` ships as a reference implementation for the
single-shot, in-memory body flow that covers most AWS service calls
(DynamoDB, S3 GET / small PUT, CloudWatch, SQS, …). Wire it into the
`requestInterceptors` chain the same way you would `HMACRequestInterceptor`:

```swift
import InnoNetwork

let signer = AWSSigV4Interceptor(
    accessKeyID: accessKey,
    secretAccessKey: secret,
    region: "us-east-1",
    service: "execute-api"
)

let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    auth: AuthPack(additionalSigners: [signer])
)
```

The interceptor recomputes the signature on every attempt because the
canonical request includes `X-Amz-Date`. The canonical path is
single-encoded for `service == "s3"` and double-encoded for every
other service to match the SigV4 rule.

For deterministic tests, inject a `now: @Sendable () -> Date` closure
that returns a fixed timestamp; ``AWSSigV4Interceptor`` exposes
``canonicalRequest(for:)`` and ``stringToSign(canonicalRequest:date:)``
so you can validate against the published AWS test vectors.

> Important: SigV4 over a streaming body needs the chunk-signed
> variant (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`). The interceptor
> contract delivers the request before the upload pipeline owns the
> body, so a streaming signer needs deeper integration than this
> recipe — file an issue if your use case requires it. Likewise,
> presigned URLs (query-string signing) and IAM role rotation are out
> of scope; use the AWS SDK for those.

## JWT bearer with auto-refresh (interceptor recipe)

For long-lived JWT bearer tokens (HS256 / RS256 / ES256), prefer
``RefreshTokenPolicy``: that surface already coalesces single-flight
refresh, replays one in-flight request after a 401, and routes around
public endpoints via `appliesTo`. A custom JWT interceptor only adds
value when the token is **minted on every request** (claims include
the request method/path) rather than rotated by the auth server.

For request-minted JWTs, use the shipped ``JWTBearerInterceptor``:
it owns the `Authorization` header carry-out and delegates the actual
token production to a `tokenProvider` closure, so the signing key
material lives in Keychain or Secure Enclave rather than inside the
interceptor.

```swift
import InnoNetwork

let jwt = JWTBearerInterceptor(
    tokenProvider: { request in
        // Construct header + claims as JSON, base64url-encode each,
        // join with ".", hand off to your signer (CryptoKit, CryptoSwift,
        // or a Keychain-backed helper), append base64url(signature).
        try await mintRequestScopedJWT(for: request)
    }
)

let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    auth: AuthPack(additionalSigners: [jwt])
)
```

The default `scheme` is `"Bearer"` and the default `headerName` is
`"Authorization"`; pass overrides at init time if your backend uses a
different scheme. The `tokenProvider` closure receives the outgoing
`URLRequest` so claims like `htu` / `htm` (DPoP) can include the
request URL and method.

## Testing your interceptor

For HMAC-style signers, derive the expected signature with the same
CryptoKit primitives in the test:

```swift
let expectedMAC = HMAC<SHA256>.authenticationCode(
    for: body,
    using: SymmetricKey(data: secret)
)
let expected = Data(expectedMAC).base64EncodedString()
```

This is the pattern used by `HMACRequestInterceptorTests` in the
package: it round-trips the same algorithm rather than checking
against an opaque vector, so the test stays meaningful even if the
backend swaps SHA-256 for SHA-384.

## See also

- ``HMACRequestInterceptor``
- ``RequestInterceptor``
- <doc:Interceptors>
- <doc:AuthRefresh>
