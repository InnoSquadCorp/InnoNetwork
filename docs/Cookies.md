# Cookie Storage Isolation

InnoNetwork creates `URLSession` instances on top of
`URLSessionConfiguration.default`, which means every
`DefaultNetworkClient` in the same process inherits
`HTTPCookieStorage.shared` unless the consumer opts out. That is the
right default for a single-account app, but it leaks cookies across
clients in three common scenarios:

- A single app signed into **multiple accounts** at once (B2B SaaS,
  family-account switchers, on-call rotations).
- A **guest / incognito session** that must not pollute the primary
  session's cookie jar.
- An **embedded SDK** that talks to a side channel and should not
  contaminate the host app's session — or vice versa.

The library exposes the override surface needed to isolate cookie
storage explicitly. This article documents the pattern; the underlying
hook lives on
``NetworkConfiguration/urlSessionConfigurationOverride``.

## Per-client cookie jar

Inject a dedicated `HTTPCookieStorage` instance through
`urlSessionConfigurationOverride`, then build the matching
`URLSession` from
``NetworkConfiguration/makeURLSessionConfiguration()``:

```swift
let isolatedCookies = HTTPCookieStorage.sharedCookieStorage(
    forGroupContainerIdentifier: "group.com.example.app.tenant-a"
)

let config = NetworkConfiguration.advanced(baseURL: baseURL) { builder in
    builder.urlSessionConfigurationOverride = { sessionConfig in
        sessionConfig.httpCookieStorage = isolatedCookies
        sessionConfig.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        return sessionConfig
    }
}

let session = URLSession(configuration: config.makeURLSessionConfiguration())
let client = DefaultNetworkClient(configuration: config, session: session)
```

> Important: `URLSession.shared` cannot honour
> `urlSessionConfigurationOverride` because the system manages its
> configuration. `DefaultNetworkClient` rejects the combination of a
> non-`nil` override and the default shared session at initialization
> time, so the failure mode is loud rather than silent.

## Cookie-free clients

For SDKs or RPC-style clients that should not persist cookies at all,
disable the storage entirely instead of swapping it out:

```swift
builder.urlSessionConfigurationOverride = { sessionConfig in
    sessionConfig.httpCookieAcceptPolicy = .never
    sessionConfig.httpCookieStorage = nil
    sessionConfig.httpShouldSetCookies = false
    return sessionConfig
}
```

This is the right default for service-to-service traffic where any
incoming `Set-Cookie` header would be a bug, not a feature.

## Multi-account registry

The pattern below scales the per-client cookie jar up to N accounts
without leaking cookies across them. Each `AccountID` owns its own
storage, its own configuration, and its own `URLSession`, so the
`Authorization` header is the only state that needs to be swapped per
caller — cookies stay separated automatically.

```swift
actor AccountSessionRegistry {
    private let baseURL: URL
    private var clients: [AccountID: DefaultNetworkClient] = [:]

    init(baseURL: URL) { self.baseURL = baseURL }

    func client(for accountID: AccountID) -> DefaultNetworkClient {
        if let existing = clients[accountID] { return existing }

        let storage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "group.com.example.app.\(accountID.rawValue)"
        )
        let config = NetworkConfiguration.advanced(baseURL: baseURL) { builder in
            builder.urlSessionConfigurationOverride = { sessionConfig in
                sessionConfig.httpCookieStorage = storage
                return sessionConfig
            }
        }
        let session = URLSession(configuration: config.makeURLSessionConfiguration())
        let client = DefaultNetworkClient(configuration: config, session: session)
        clients[accountID] = client
        return client
    }
}
```

When an account signs out, drop the corresponding entry from
`clients` and call `storage.removeCookies(since: .distantPast)` to
purge cookies from disk.

## Verifying isolation

Two clients pointing at the same host should never observe each
other's cookies. A focused integration test that logs in twice and
inspects the per-client `HTTPCookieStorage` is the cheapest way to
confirm that:

```swift
let cookiesA = storageA.cookies(for: baseURL) ?? []
let cookiesB = storageB.cookies(for: baseURL) ?? []
#expect(Set(cookiesA.map(\.value)).isDisjoint(with: cookiesB.map(\.value)))
```

A leak surfaces immediately as a non-empty intersection.

## See also

- ``NetworkConfiguration/urlSessionConfigurationOverride``
- ``NetworkConfiguration/makeURLSessionConfiguration()``
- [Background Session Sharing](AppGroupSharedSession.md) for the
  cross-process variant (Share Extension, Widget Extension).
