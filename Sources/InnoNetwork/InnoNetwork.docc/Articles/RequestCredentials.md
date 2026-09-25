# Origin-bound request credentials

Use an application-owned provider for named API keys or explicitly selected
combinations of API key and opaque bearer credentials.

## Overview

Conform an endpoint to ``RequestSecurityProviding`` alongside ``APIDefinition``
or ``MultipartAPIDefinition``. Its ``RequestSecurity`` contains metadata and a
``RequestCredentialProvider``, not static credentials. Use anonymous legacy
session authentication on that endpoint to avoid overlapping token ownership.
The `@APIDefinition` macro and existing session bearer contracts are unchanged.

For a hand-written macro endpoint that stores this configuration, use the macro's
existing complete manual payload contract. This keeps `requestSecurity` out of
query/body inference without adding a new macro mode:

```swift
@APIDefinition(method: .get, path: "/health", auth: .anonymous)
struct SecuredHealth: RequestSecurityProviding {
    typealias APIResponse = EmptyResponse
    typealias Parameter = EmptyParameter
    var parameters: EmptyParameter? { nil }
    let requestSecurity: RequestSecurity
}
```

For requests with payloads, supply the appropriate `Parameter` type and
`parameters` value instead; the macro still generates the remaining endpoint
contract. The OpenAPI generator emits the explicit endpoint contract directly.

The provider explicitly chooses one outer alternative. Every member of that
alternative is required. Selecting an empty alternative explicitly permits an
anonymous request; a failed authenticated alternative never falls back to it.
This models [OpenAPI security requirements](https://spec.openapis.org/oas/v3.0.3.html#security-requirement-object).

## Ownership and ordering

The client freezes selection for each logical request, including retries. The
provider supplies non-secret realm/principal identifiers and attests that every
credential belongs to that identity. Identifiers are never derived from tokens.
Two separate calls using the same endpoint create independent selections.

After interceptors run, the final request must match the configured HTTPS
origin. Credential acquisition happens after rate/admission waits and before
configuration and endpoint signers. Every credential in an AND group must be
available and valid before transport. A signer cannot overwrite the provider's
credential. Retries reacquire credentials for the same selected identity, so a
provider can rotate a key without silently switching accounts.

Providers must cooperate with cancellation. The executor also checks after each
callback and never dispatches if a non-cooperating callback returns after cancel.
OAuth login UI, credential issuance/storage and secret rotation remain owned by
the application; do not ship long-lived server secrets in a client binary.

## Conservative isolation

Requests using this contract bypass library response caching, in-flight
coalescing and URLCache. They disable cookie-jar handling and automatic redirects,
including same-origin redirects: a redirected envelope needs fresh origin and
signature checks. This remains true for an explicitly selected anonymous branch.
Principal-partitioned sharing is not implemented merely because identity metadata
is present. Streaming rejects this opt-in contract before transport for now.
Native session-level Authorization, Cookie or selected API-key header defaults
are rejected. Non-server-trust authentication challenges are cancelled rather
than allowing Foundation to select another credential method/account.

Header keys are the default. Query/cookie declarations require explicit flags
when constructing `RequestSecurity`, even if another OR branch will be selected.
The declared location is never rewritten. Existing credential slots fail rather
than being replaced. Caller cookies are not merged; multiple selected cookie keys
are assembled together using the [RFC 6265 cookie-octet subset](https://www.rfc-editor.org/rfc/rfc6265.html#section-4.1.1).

## Diagnostics and secrets

Provider and signer errors do not retain arbitrary error descriptions. Failure
codes use ``RequestSecurityFailure`` in `InnoNetwork.RequestSecurity` through
`NetworkError.underlying`. Transport retry categories are retained while their
arbitrary descriptions are removed. Observers, endpoint logging and the returned
request snapshot use the unsigned request. Declared secret response header slots
and query slots in response URLs are redacted.
The built-in retry policy does not retry credential-boundary failures. The
operation-first adapter classifies them as configuration failures with
`doNotRetry`; use the typed `NetworkError` boundary when the detailed provider
failure code is needed. Ordinary transport/status retries still retain selection.

VCR recording/replay automatically redacts the dynamically declared header,
query and cookie fields, and recording forwards the redirect/cache context.
VCR still records response bodies: do not record servers that echo credentials
or other sensitive payloads without application-owned response scrubbing. Use
separate cassettes for different principals; redacted cassette matching is not
a production principal-isolation mechanism. Custom providers, signers, transports
and interceptors are trusted application code and must not log secrets themselves.
`NetworkMetricsReporting` is also a trusted raw Foundation metrics callback;
its task/transaction request snapshots can contain wire credentials. Redact them
inside the reporter, or use the secret-free event/span observation surface.

## Current limits

Metadata is bounded to 32 alternatives, 16 schemes per alternative, and
256-byte identifiers/names. Credential values are capped at 8192 UTF-8 bytes;
header, bearer and cookie values enforce their wire character subsets.
Names currently use ASCII HTTP tokens even for query placement. Routing, framing,
cookie and hop-by-hop headers cannot be API-key header names.

OAuth scopes, expiry metadata and automatic OAuth refresh are a subsequent stage.
An opaque bearer requirement here does not imply any scope validation or refresh.
These APIs are Provisionally Stable; generated OpenAPI output remains Preview.

## Topics

- ``RequestSecurityProviding``
- ``RequestCredentialProvider``
- ``RequestSecurity``
- ``RequestSecurityFailure``
