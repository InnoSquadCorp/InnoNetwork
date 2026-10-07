# Buffered encoded requests — new in 6.1.0

`EncodedRequest<Output: Sendable>` decouples HTTP execution from Codable.
`EncodedRequestBody` supplies content type, optional byte budget, and a deferred
Sendable encoder. `AnyResponseDecoder<Output>` receives buffered Data and response
metadata. These are buffered codecs, not a streaming upload/response API.

For a named endpoint, implement `EncodedAPIDefinition` and
`makeEncodedRequest() throws(NetworkError)`. Its declared method, path and
authentication must equal those on the returned request. Constructing that
request prepares the encoder without performing I/O. The
[UploadBytes example](../assets/consumer/Sources/NetworkSkillExample/Endpoints.swift)
returns a non-Codable value through the actual client pipeline.

## Encoding, retries and failures

- Encoding happens after URL/auth preflight, once per client invocation. Retry
  and refresh replays reuse those bytes; calling the client again encodes again.
- Capture immutable Sendable input. A failed encoder is also memoized within
  the invocation. Foreign encoder errors become payload-free
  `.configuration(reason: .invalidPayload(.encoding))`, not transport retries.
- A cancellation thrown by either codec stays `.cancelled`. Do not wrap it as
  an ordinary decoding/configuration failure and retry it.
- A nil body and an encoder returning zero bytes are different: the latter
  supplies a content type and an empty body. GET cannot carry an encoded body.
- Named `RequestSecurityProviding` credentials are rejected before factory
  execution on this boundary. Session bearer auth and request signers are
  supported. Use the existing JSON/multipart credential path if that is the
  required contract; do not silently remove credentials.

## Resource and response contracts

`EncodedRequestBody.maximumBytes` checks the output **after** allocation.
Use a bounded encoder or the appropriate file-backed Upload product for inputs
too large to buffer. Negative budgets are invalid. `maximumResponseBytes`
tightens, never increases, the configured client response cap. Coalescing only
shares equivalent effective limits; do not assume one transport attempt for
different caps.

`.noContent()` requires both an empty body and status 204 or 205 by default.
It is not a generic empty-message decoder. Custom no-content status sets replace
those defaults, and must also agree with accepted HTTP status policy. A binary
codec owns its own format/media-type validation; raw bytes do not prove a valid
Protobuf or other serialized message.

`codecObserver` reports payload-free stage, byte count, duration and success.
It counts codec invocations, not physical HTTP attempts. Keep callbacks short
and avoid logging bytes, credentials, or arbitrary encoder error strings.

Sources:
[encoded request types and execution](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetwork/EncodedRequest.swift),
[named endpoint bridge](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetwork/EncodedAPIDefinition.swift),
[stability ledger](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/API_STABILITY.md).
