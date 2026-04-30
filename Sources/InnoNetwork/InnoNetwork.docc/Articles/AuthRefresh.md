# Auth Refresh

Use ``RefreshTokenPolicy`` when a client should refresh a bearer token after an
authentication response and replay the fully adapted request once.

Auth refresh is part of InnoNetwork's internal execution pipeline, not a public
generic execution-policy hook. The public surface is intentionally narrow:
callers provide closures for reading the current token, refreshing it, and
optionally applying it to a ``URLRequest``.

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
