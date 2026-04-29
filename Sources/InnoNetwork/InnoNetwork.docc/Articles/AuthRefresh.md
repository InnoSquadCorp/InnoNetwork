# Auth Refresh

Use ``RefreshTokenPolicy`` when a client should refresh a bearer token after an
authentication response and replay the original request once.

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
- replay the original request at most once
- surface refresh failures to every waiting request

Provide `refreshStatusCodes:` or `applyToken:` only when your API differs from
standard bearer-token authentication.

