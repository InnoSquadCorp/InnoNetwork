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

let configuration = NetworkConfiguration.advanced(baseURL: baseURL) { builder in
    builder.requestInterceptors.append(signer)
}

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
struct CanonicalSigner: RequestInterceptor {
    let keyID: String
    let secret: SymmetricKey
    let clock: any InnoNetworkClock

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        guard let url = urlRequest.url else {
            throw NetworkError.invalidRequestConfiguration("Missing URL for signing")
        }
        if urlRequest.httpBodyStream != nil {
            throw NetworkError.invalidRequestConfiguration(
                "Streaming bodies require a streaming-aware signer"
            )
        }

        let timestamp = String(Int(clock.now.timeIntervalSince1970))
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

Inject your own `InnoNetworkClock` so tests can pin the timestamp.
The pattern composes with retries because `adapt(_:)` is called once
per attempt — every retry produces a fresh `timestamp` / `nonce`
pair, side-stepping replay protection on the backend.

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
