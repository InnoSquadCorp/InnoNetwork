# Core JSON integration — 6.1.0

Start with only the `InnoNetwork` product in application targets. A SwiftPM
consumer can declare `.package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
exact: "6.1.0")`; the fixture shows the complete manifest. Default traits enable
`@APIDefinition`. Manual conformance is available when the consumer intentionally
disables macros, but disabling a trait does not remove manifest resolution.

For a named API, keep an explicit struct with inputs and `APIResponse`:

```swift
import InnoNetwork

struct User: Decodable, Sendable { let id: Int; let name: String }

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User
    let id: Int
}
```

`DefaultNetworkClient(baseURL:)` is sufficient for a small application. Use
`NetworkConfiguration.safeDefaults(baseURL:)` or the public `advanced` packs
when a concrete policy requires configuration; do not recreate stored internals.
`try await client.request(GetUser(id: 7))` throws `NetworkError`.

Use a stored `body` or `query` with an Encodable, Sendable type for supported
macro payload inference. Member-level conditional payloads are not inferred;
use a whole-endpoint conditional or a complete unconditional `Parameter` and
`parameters` pair. A manual pair is authoritative. The 6.1 diagnostic makes
this existing limitation visible and can fail warnings-as-errors consumers.

## Test using public consumer surfaces

Link `InnoNetworkTestSupport` **only to test/preview targets**. Importing it
adds public `DefaultNetworkClient(configuration:session:)` overloads for
`MockURLSession` and `VCRURLSession`; a generic `URLSessionProtocol` injection
initializer in Core is package-scoped. `StubNetworkClient` is another public
option for JSON response stubbing. `TestClock` and `FaultInjection` are not
downstream APIs.

The [consumer tests](../assets/consumer/Tests/NetworkSkillExampleTests/ConsumerTests.swift)
exercise the production client through the public mock overload, avoiding
`@testable` on InnoNetwork. They inspect sent method/path/body, response values,
attempt counts, encoding counts, and failures. Mock responses already exist in
memory, so byte-limit tests do not establish real transport allocation bounds.

Sources at the verified revision:
[macro declaration](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetwork/APIDefinition%2BMacro.swift),
[public test-session overloads](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetworkTestSupport/DefaultNetworkClient%2BTestSession.swift),
[README](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/README.md).
