# UrlSession Escape Hatch — Alternatives Guide

`NetworkConfiguration.urlSessionConfigurationOverride` and the matching
field on `TransportPack` accept a raw
`(URLSessionConfiguration) -> URLSessionConfiguration` closure that runs
right before the underlying `URLSession` is constructed. The hook exists
because some configurations cannot be expressed through the rest of the
policy surface today — most notably the multi-account cookie isolation
recipe in [`Cookies.md`](Cookies.md) — and removing it would close that
door.

That said, reaching for the hook is **discouraged for general use**.
Every callsite that hand-writes URLSession state bypasses the policy-axis
design that gives reviewers a single, typed surface to reason about
retry, caching, redirect, reachability, and trust. The hook is therefore
called out in the API docs as a leaky abstraction and is left in place
only to keep the sanctioned scenarios working.

## Sanctioned use cases (no first-class axis exists today)

| Scenario | Why no axis | Notes |
|---|---|---|
| Multi-account `HTTPCookieStorage` isolation | Cookie storage is per-`URLSession`; a per-policy axis would have to model account scope alongside it. | Follow [`Cookies.md`](Cookies.md). Set both `httpCookieStorage` and (when needed) `httpCookieAcceptPolicy` inside the closure. |
| Per-environment `URLCredentialStorage` swap | Same shape as above — credential storage is session-scoped. | Use the closure to set `urlCredentialStorage`; nothing else inside the closure should change. |

## Use cases that already have first-class axes

If you find yourself reaching for the hook for one of these, switch to
the corresponding policy:

| What you want to set | First-class axis |
|---|---|
| Request timeout | `NetworkConfiguration.timeout` |
| Resource transfer timeout | `NetworkConfiguration.timeout` (carried into `timeoutIntervalForResource`) |
| Cellular allowance | `allowsCellularAccess` |
| Expensive network allowance | `allowsExpensiveNetworkAccess` |
| Constrained network allowance | `allowsConstrainedNetworkAccess` |
| HTTP cache policy | `cachePolicy` |
| Redirect handling | `redirectPolicy` |
| Insecure HTTP allowlist | `allowsInsecureHTTP` |
| Server trust pinning | `TrustPolicy` (via configuration's trust integration) |
| Request prioritization | `requestPriority` |

## Filing a request

If your use case is none of the sanctioned scenarios above and is not
covered by an existing axis, please open a GitHub issue describing the
configuration property you need to control and the user-facing behaviour
that requires it. The maintainer will weigh shipping a typed axis (the
preferred outcome) against expanding the sanctioned-use-case list here.

The escape hatch is not going away in the 4.x line, but new
sanctioned use cases will be documented in this file rather than left
implicit so the API surface stays inspectable.
