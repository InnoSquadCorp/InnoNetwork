# Auth Refresh

Use ``RefreshTokenPolicy`` when a client should refresh a bearer token after an
authentication response and replay the fully adapted request once.

Auth refresh is part of InnoNetwork's internal execution pipeline, not a public
retry policy. The public surface stays narrow: callers provide closures for
reading the current token, refreshing it, and optionally applying it to a
`URLRequest`.

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: {
        try await tokenStore.currentAccessToken()
    },
    refreshToken: {
        try await authService.refreshAccessToken()
    }
)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        auth: AuthPack(refreshToken: refreshPolicy)
    )
)
```

The default behaviour is:

- apply the current token before transport when one is available
- refresh on `401`
- collapse concurrent refreshes into one in-flight operation
- return a cancelled waiter promptly without cancelling a shared refresh for
  other requests; releasing the coordinator cancels an orphaned in-flight
  refresh task
- replay the fully adapted request at most once, preserving session and
  endpoint interceptor headers while clearing the prior `Authorization` header
  before reapplying so custom applicators that use `addValue` stay idempotent
- surface a refresh failure to every waiting request, then hold a short
  failure cooldown (`failureCooldown:`, exponential from 1 s up to 30 s by
  default). A `401` that arrives during the cooldown fails with the same
  refresh error instead of calling a known-bad refresh again; after the
  cooldown the next `401` starts a fresh refresh attempt. Pass
  `failureCooldown: .disabled` to make every failure immediately retryable
- apply the same single replay to a `stream(_:)` handshake rejected with a
  refresh status, before any body byte is delivered

Provide `refreshStatusCodes:` or `applyToken:` only when your API differs from
standard bearer-token authentication.

## Handle a Failed Refresh

When a session refresh fails in a way that shows the session cannot be
renewed, the request throws ``NetworkError/authentication(_:)`` with
``NetworkAuthenticationFailure/refreshFailed(_:)``. Every refresh follows the
same rule: the replay after a refresh status (`401` by default) and the
proactive refresh of a `.required` request that has no token yet. That covers:

- a refresh request that the server rejected with a status that is not
  transient, for example `400 invalid_grant`, `401`, `403`, or `404`;
- a `URLError` that reports a rejected credential:
  `.userAuthenticationRequired`, `.userCancelledAuthentication`,
  `.clientCertificateRejected`, or `.clientCertificateRequired`;
- a token response that cannot be decoded;
- an error of your own type thrown by the `refreshToken` closure.

The payload is a ``SendableUnderlyingError`` snapshot of the error the refresh
operation produced. Replaying the request cannot repair the session, so the
built-in retry policy never retries this failure, the circuit breaker never
counts it, and ``NetworkErrorSummary/recovery`` recommends
``NetworkRecoveryDisposition/reauthenticate``.

```swift
do {
    let profile = try await client.request(GetProfile())
    render(profile)
} catch NetworkError.authentication(.refreshFailed) {
    await session.signOut()
    presentSignIn()
} catch {
    present(error)
}
```

A refresh that fails for a reason that says nothing about the session keeps
the refresh error's own case, because the session may still be valid. The
request then follows the ordinary retry and recovery rules:

- Cancellation stays ``NetworkError/cancelled``.
- A connectivity failure stays ``NetworkError/reachability(_:_:_:)``, and a
  timeout stays ``NetworkError/timeout(reason:underlying:)``.
- A `408`, `429`, or `5xx` from the refresh endpoint stays
  ``NetworkError/statusCode(_:)``. Its ``Response`` is the refresh endpoint's
  response, not the response to your request, and carries no request: the
  refresh request's body and headers hold the refresh token.
- Any other `URLError` is an unclassified transport error and stays
  ``NetworkError/underlying(_:_:)``.
- A configuration failure, including an offline device, stays
  ``NetworkError/configuration(reason:)``. A local policy rejection, such as an
  open circuit for the token host, stays ``NetworkError/policyRejected(_:)``,
  and a trust failure stays ``NetworkError/trustEvaluationFailed(_:)``.

Only an error that comes from a transport — a ``NetworkError`` or a `URLError` —
can count as transient, and a credential-rejection `URLError` never does. Any
other error type thrown by the `refreshToken` closure is treated as the
closure's verdict on the session, so rethrow a `URLError` or ``NetworkError``
that your token client received instead of wrapping it in your own error type.
A refresh request sent through an InnoNetwork client already reports its
status as ``NetworkError/statusCode(_:)``. A token client that checks the HTTP
status itself can follow the Auth example in the repository: throw
`URLError(.userAuthenticationRequired)` for `400`, `401`, and `403`, which
reject the refresh credential, and `URLError(.badServerResponse)` for any other
unsuccessful status, which keeps the request retryable.

A `401` that arrives during the failure cooldown fails with the stored refresh
error, classified by the same rules. A retry that runs during the cooldown
therefore receives that error again without calling `refreshToken`, and still
uses up one retry. When a transient refresh failure should reach the refresh
endpoint again on the next retry, keep the retry policy's shortest delay,
after jitter, at least as long as the cooldown. The default cooldown is 1
second after the first failure and doubles with each consecutive failure of
the same realm, up to 30 seconds. With the defaults of
``ExponentialBackoffRetryPolicy``, the first retry runs 0.8 to 1.2 seconds
after the failure, so it can fall inside even the first cooldown.
A `401` that the server returns after a successful refresh stays
``NetworkError/statusCode(_:)``.

## URLSession Cache Policy

`URLSession`'s cache keys entries by URL, not by credential. A request that
reaches transport with a credential header — `Authorization`,
`Proxy-Authorization`, `Cookie`, `X-API-Key`, `X-Auth-Token`, or a header
listed in `CachePack(sensitiveHeaderNames:)` — therefore never has its
response stored in that cache, whatever its cache policy. Under the default
`.useProtocolCachePolicy` it does not read the cache either: it is sent with
`.reloadIgnoringLocalCacheData`. Only an explicitly cache-first policy,
`.returnCacheDataElseLoad` or `.returnCacheDataDontLoad`, opts out of both. The
check runs after request interceptors and token application, so it covers a
credential that your own request interceptor adds as well as the token that
``RefreshTokenPolicy`` applies, whether the configuration comes from
``NetworkConfiguration/safeDefaults(baseURL:)`` or from `advanced`. The
library's own response cache (``CachePack``) is not affected.

Configuring `AuthPack(refreshToken:)` also changes one transport default of
``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)``.
When ``TransportPack`` does not set a `cachePolicy`, every request of that
client uses `.reloadIgnoringLocalCacheData`, so a response fetched with one
session's token is not served from `URLSession`'s cache after the session
changes, even when the token travels in a header the library does not
recognize as a credential. The same default applies when ``CachePack`` sets a
`responseCachePolicy` other than `.disabled`.

A client that does not use `AuthPack` and sends a credential in a custom
header should list that header in `CachePack(sensitiveHeaderNames:)`, which
also keeps its responses out of `URLSession`'s cache, or set
`TransportPack(cachePolicy: .reloadIgnoringLocalCacheData)`.

## Isolate Multiple Authentication Realms

Use the realm-aware initializer when one client reaches multiple tenants,
principals, or identity providers. Returning `nil` excludes a request from the
policy. Non-nil realms keep independent refresh tasks, generations, and failure
cooldowns.

```swift
let refreshPolicy = RefreshTokenPolicy(
    realmForRequest: { request in
        switch request.url?.host {
        case "customer.example.com": "customer"
        case "operator.example.com": "operator"
        default: nil
        }
    },
    currentToken: { realm in
        try await tokenStore.currentAccessToken(for: realm.rawValue)
    },
    refreshToken: { realm in
        try await authService.refreshAccessToken(for: realm.rawValue)
    }
)
```

Realm identifiers are process-memory routing keys, not credentials. Avoid
putting access tokens or other secrets in ``AuthenticationRealm/rawValue``.

## Shared Refresh Task Ownership

The refresh operation is intentionally owned by the coordinator, not by the
first request that observes `401`. Internally that shared work may use a
detached task boundary so one caller's cancellation or priority does not
cancel or downgrade the refresh needed by other waiting requests. A cancelled
waiter returns promptly, while the coordinator keeps the refresh alive until it
succeeds, fails, or the coordinator is released.

## Mark Auth-Required Endpoints

Choose `.required` explicitly so an authenticated endpoint cannot silently run
through a client configuration that has no token provider:

```swift
struct Profile: Decodable, Sendable {
    let id: String
}

let endpoint = EndpointBuilder<EmptyResponse>
    .get("/me")
    .authentication(.required)
    .decoding(Profile.self)

let profile = try await client.request(endpoint)
```

Custom endpoint definitions can opt into the same preflight guard:

```swift
struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile
    let method: HTTPMethod = .get
    let path = "/me"
    let sessionAuthentication: SessionAuthentication = .required
}
```

If the client was not built with `AuthPack(refreshToken:)`, the request fails
before transport with ``NetworkError/configuration(reason:)`` and
``NetworkConfigurationFailureReason/invalidRequest(_:)``. Named manual
endpoints must also declare `sessionAuthentication`; use `.anonymous` when the
request must never participate in bearer-token refresh, or `.optional` when it
may use a configured token but is allowed to proceed without one.
