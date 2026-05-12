# Cookie Storage Isolation

`DefaultNetworkClient(configuration:)` creates a fresh `URLSession` from
`URLSessionConfiguration.default`, then installs per-client cookie storage and
an in-memory URL cache. That default avoids accidental leakage across clients,
but some apps still need an explicit cookie surface in three common scenarios:

- A single app signed into **multiple accounts** at once (B2B SaaS,
  family-account switchers, on-call rotations).
- A **guest / incognito session** that must not pollute the primary
  session's cookie jar.
- An **embedded SDK** that talks to a side channel and should not
  contaminate the host app's session — or vice versa.

The library does not ship a named cookie-policy hook on
`NetworkConfiguration` itself; `URLSessionConfiguration` is the right place to
set custom cookie storage, and `DefaultNetworkClient` accepts an injected
`URLSession`. The pattern below uses the configuration's
`makeURLSessionConfiguration()` as a starting point, which carries timeout,
cache, and network-access defaults, then mutates the cookie surface directly
and hands the resulting session to `DefaultNetworkClient(configuration:session:)`.

## Per-client cookie jar

```swift
let isolatedCookies = HTTPCookieStorage.sharedCookieStorage(
    forGroupContainerIdentifier: "group.com.example.app.tenant-a"
)

let config = NetworkConfiguration.safeDefaults(baseURL: baseURL)
let sessionConfig = config.makeURLSessionConfiguration()
sessionConfig.httpCookieStorage = isolatedCookies
sessionConfig.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain

let session = URLSession(configuration: sessionConfig)
let client = DefaultNetworkClient(configuration: config, session: session)
```

`URLSession.shared` cannot honour a custom `httpCookieStorage` because the
system manages its configuration; pass an explicit `URLSession` built from
`makeURLSessionConfiguration()` when you need an app-group jar, tenant-specific
jar, or cookie-free transport.

## Cookie-free clients

For SDKs or RPC-style clients that should not persist cookies at all,
disable the storage entirely instead of swapping it out:

```swift
let sessionConfig = config.makeURLSessionConfiguration()
sessionConfig.httpCookieAcceptPolicy = .never
sessionConfig.httpCookieStorage = nil
sessionConfig.httpShouldSetCookies = false
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
        let config = NetworkConfiguration.safeDefaults(baseURL: baseURL)
        let sessionConfig = config.makeURLSessionConfiguration()
        sessionConfig.httpCookieStorage = storage
        let session = URLSession(configuration: sessionConfig)
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


- ``NetworkConfiguration/makeURLSessionConfiguration()``
- [Background Session Sharing](AppGroupSharedSession.md) for the
  cross-process variant (Share Extension, Widget Extension).
