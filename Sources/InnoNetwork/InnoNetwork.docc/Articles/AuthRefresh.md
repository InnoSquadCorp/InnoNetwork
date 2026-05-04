# Auth Refresh

Use ``RefreshTokenPolicy`` when a client should refresh a bearer token after an
authentication response and replay the fully adapted request once.

Auth refresh is part of InnoNetwork's internal execution pipeline, not a public
retry policy. The public surface stays narrow: callers provide closures for
reading the current token, refreshing it, and optionally applying it to a
``URLRequest``.

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
        baseURL: URL(string: "https://api.example.com")!
    ) { builder in
        builder.refreshTokenPolicy = refreshPolicy
    }
)
```

The default behaviour is:

- apply the current token before transport when one is available
- refresh on `401`
- collapse concurrent refreshes into one in-flight operation
- replay the fully adapted request at most once, preserving session and
  endpoint interceptor headers while clearing the prior `Authorization` header
  before reapplying so custom applicators that use `addValue` stay idempotent
- surface refresh failures to every waiting request, while a *failed* refresh
  is not cached: the next 401 will start a fresh refresh attempt instead of
  replaying the previous failure

Provide `refreshStatusCodes:` or `applyToken:` only when your API differs from
standard bearer-token authentication.

## Mark Auth-Required Endpoints

4.0.0 adds a type-level auth marker so an authenticated endpoint cannot
silently run through a public client configuration:

```swift
struct Profile: Decodable, Sendable {
    let id: String
}

let endpoint = ScopedEndpoint<EmptyResponse, AuthRequiredScope>
    .get("/me")
    .decoding(Profile.self)

let profile = try await client.request(endpoint)
```

Custom endpoint definitions can opt into the same preflight guard:

```swift
struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile
    typealias Auth = AuthRequiredScope

    let method: HTTPMethod = .get
    let path = "/me"
}
```

If the client has no ``NetworkConfiguration/refreshTokenPolicy``, the request
fails before transport with ``NetworkError/invalidRequestConfiguration(_:)``.
Public endpoints use ``PublicAuthScope`` by default and do not require a
refresh policy.
