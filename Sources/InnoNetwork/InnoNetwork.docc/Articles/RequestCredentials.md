# Origin-bound request credentials

Use an application-owned provider for named API keys or explicitly selected
combinations of API keys, opaque bearer and scoped OAuth bearer credentials.

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

## Scoped OAuth and renewal

Declare `.oauth2(id:scopes:)` and supply `grantedScopes` and `expiresAt` with the
credential. Scope spelling is case-sensitive; unknown metadata fails closed.
The attested grants must contain every declared scope. Core does not decode a
JWT as proof of permission: issuer/audience validation and metadata attestation
belong to the provider, and the resource server remains the authorization authority.

To renew, optionally conform the provider to ``OAuthCredentialRefreshing``.
An expired credential with sufficient known grants triggers one renewal before
dispatch. Identity, scopes, value and expiry are checked again, including after
other AND credentials and asynchronous signers. One logical request permits at
most one renewal across all attempts. Invalid/missing scope metadata never
triggers a permission request or login UI.

A GET/HEAD receiving `401` with one unambiguous Bearer `invalid_token` challenge
may renew and replay once, reacquiring the complete AND group. Other methods,
missing/combined/malformed challenges and `insufficient_scope` never trigger this
automatic replay. Server-suggested scopes are never adopted. These conservative
rules build on [RFC 6750 errors](https://www.rfc-editor.org/rfc/rfc6750.html#section-3.1)
and [OAuth refresh scope limits](https://www.rfc-editor.org/rfc/rfc6749.html#section-6).

Overlapping renewals share one task only within a reused `RequestSecurity` value,
for the exact scheme/scopes and frozen realm/principal. Independent configuration
values never share credentials. A provider used by multiple configurations must
coordinate its own shared rotating refresh token and persist replacements before
returning; core does not provide an IdP-wide refresh-token store or failure cooldown.
The coordinator retains only in-flight work, limited to 64 groups and 128 waiters
per group. Cancelling a waiter does not cancel peers; cancelling the last waiter
cancels the provider task. Providers must cooperate with cancellation.

## Current limits

Metadata is bounded to 32 alternatives, 16 schemes per alternative, and
256-byte identifiers/names. Credential values are capped at 8192 UTF-8 bytes;
header, bearer and cookie values enforce their wire character subsets.
Names currently use ASCII HTTP tokens even for query placement. Routing, framing,
cookie and hop-by-hop headers cannot be API-key header names.

OAuth requirements allow up to 64 scopes, granted metadata up to 256 scopes, and
each scope up to 256 UTF-8 bytes using the OAuth scope-token syntax. An opaque
`.bearer` requirement still does not imply scope validation or OAuth refresh.
These APIs are Provisionally Stable; generated OpenAPI output remains Preview.

## Topics

- ``RequestSecurityProviding``
- ``RequestCredentialProvider``
- ``OAuthCredentialRefreshing``
- ``RequestSecurity``
- ``RequestSecurityFailure``
