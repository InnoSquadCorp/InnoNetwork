# Request Signing

Sign the final encoded request with access to the exact data or file bytes that
the transport will send.

> Important: This page documents the unreleased 5.0 preview on `main`, not a
> tagged 5.0 release.

## Overview

Use ``RequestSigner`` when authentication depends on the request body, final
URL, method, or headers. ``RefreshTokenPolicy`` remains the right abstraction
for session-rotated bearer tokens; a signer covers request-minted JWTs, HMAC,
AWS Signature Version 4, and similar per-attempt authentication schemes.

The planned 5.0 execution order is fixed in the current preview:

1. Encode the endpoint payload and create a stable snapshot for caller-owned
   files when signing requires one.
2. Run configuration and endpoint ``RequestInterceptor`` values.
3. Apply the current token from ``RefreshTokenPolicy``.
4. Run configuration signers, then endpoint signers. Each signer sees headers
   returned by the preceding signer.
5. Send the signed request and the exact ``RequestBody`` that was signed.

Signing runs again for every retry attempt and after a refresh-token replay.
Header values returned by a signer use single-value replacement semantics.

## Choose a signer

| Backend convention | Recommendation |
| --- | --- |
| `HMAC(secret, body)` plus a key id | Use ``HMACRequestInterceptor``. |
| Request-minted JWT in `Authorization` | Use ``JWTBearerInterceptor``. |
| AWS Signature Version 4 | Add the `InnoNetworkAuthAWS` product and use `AWSSigV4Interceptor`. |
| Custom canonical string or nonce scheme | Implement ``RequestSigner``. |
| Chunk-signed streaming protocol | Use a protocol-specific transport; opaque `httpBodyStream` values are intentionally unsupported. |

Despite their legacy `Interceptor` suffixes, the HMAC, JWT, and AWS types in
the preview conform to ``RequestSigner`` as planned for 5.0.

## Configure HMAC signing

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
```

`HMACRequestInterceptor` incrementally reads stable file bodies instead of
loading the entire file into memory. Override `signatureHeaderName` and
`keyIDHeaderName` when the server uses different field names.

## Implement a custom signer

A signer cannot replace the executor-owned URL, method, or body. It receives a
read-only request value and returns only the headers to merge:

```swift
import CryptoKit
import Foundation
import InnoNetwork

struct CanonicalSigner: RequestSigner {
    let keyID: String
    let secret: SymmetricKey
    let now: @Sendable () -> Date

    func signatureHeaders(
        for request: URLRequest,
        body: RequestBody
    ) async throws -> HTTPHeaders {
        guard let url = request.url else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Missing URL for signing")
            )
        }

        let timestamp = String(Int(now().timeIntervalSince1970))
        let bodyDigest = try sha256(body)
        let canonical = [
            request.httpMethod ?? "GET",
            url.path,
            url.query ?? "",
            timestamp,
            bodyDigest.base64EncodedString(),
        ].joined(separator: "\n")
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: secret
        )

        return HTTPHeaders([
            HTTPHeader(name: "X-Key-Id", value: keyID),
            HTTPHeader(name: "X-Timestamp", value: timestamp),
            HTTPHeader(
                name: "X-Signature",
                value: Data(mac).base64EncodedString()
            ),
        ])
    }

    private func sha256(_ body: RequestBody) throws -> Data {
        var hasher = SHA256()
        switch body {
        case .none:
            break
        case .data(let data):
            hasher.update(data: data)
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 64 * 1024),
                !chunk.isEmpty
            {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        }
        return Data(hasher.finalize())
    }
}
```

The URL in ``RequestBody/file(_:)`` points to an InnoNetwork-owned immutable
snapshot for that execution. Read it during `signatureHeaders(for:body:)`; do
not retain it after the signer returns. The snapshot is removed after the
transport attempt completes.

## Sharing and redirect boundaries

A signer may establish the authentication principal, but the unsigned request
does not yet carry a safe principal partition. Signed requests therefore:

- bypass InnoNetwork response-cache reads and writes;
- do not join in-flight request coalescing;
- use `URLRequest.CachePolicy.reloadIgnoringLocalCacheData`, add
  `Cache-Control: no-store`, and reject URLSession cache storage; and
- reject automatic redirects, including same-origin redirects, because the
  URLSession-generated follow-up would not pass through the async signer.

If a signed endpoint intentionally redirects, surface the 3xx response, verify
the target in application policy, and issue a new typed request so the target
is encoded and signed from the beginning. Circuit-breaker health remains keyed
by unsigned origin because it measures transport availability rather than
response identity.

## File and stream bodies

Data and explicit file payloads are supported. For caller-owned files,
InnoNetwork snapshots the source before the signer reads it, and the transport
uploads that same snapshot. Mutating or deleting the caller's original file
after execution starts cannot change the signed bytes.

Opaque `URLRequest.httpBodyStream` bodies are rejected because reading them
would consume the wire stream. Use `RequestPayload.data(_:)` or
`RequestPayload.fileURL(_:contentType:)`, or adopt a transport designed for the
backend's streaming-signature protocol.

## AWS SigV4

`InnoNetworkAuthAWS.AWSSigV4Interceptor` supports ordinary header-based SigV4
for empty, data-backed, and stable file-backed bodies. It adds the S3 payload
hash header when `service == "s3"` and incrementally hashes file snapshots.
Streaming SigV4, presigned URLs, credential-provider chains, and automatic IAM
rotation remain out of scope; use an AWS SDK when those are required.

For deterministic tests, inject a fixed `now` closure and compare the returned
headers with published AWS vectors.

## Request-minted JWT

Use ``JWTBearerInterceptor`` only when claims depend on the final request and a
new token must be minted per attempt. Its `tokenProvider` sees the final URL,
method, and interceptor/refresh headers. If it returns `Authorization`, that
late value intentionally replaces an earlier refresh-token header.

For ordinary OAuth-style session tokens, use ``RefreshTokenPolicy`` instead so
concurrent 401 responses share one refresh generation.

## See also

- ``RequestSigner``
- ``RequestBody``
- ``HMACRequestInterceptor``
- ``JWTBearerInterceptor``
- <doc:Interceptors>
- <doc:AuthRefresh>
