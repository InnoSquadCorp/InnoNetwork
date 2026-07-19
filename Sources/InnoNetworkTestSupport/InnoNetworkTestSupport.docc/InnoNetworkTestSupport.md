# ``InnoNetworkTestSupport``

Deterministic test doubles, request stubs, WebSocket recording, and redacted
HTTP cassette support for consumer test targets.

## Overview

Add `InnoNetworkTestSupport` only to test targets. Its public types help tests
exercise a production `DefaultNetworkClient`, replace a `NetworkClient` with a
typed stub, record WebSocket events, or record and replay HTTP interactions.

```swift
import Foundation
import InnoNetwork
import InnoNetworkTestSupport

struct User: Codable, Sendable {
    let id: Int
    let name: String
}

let session = MockURLSession()
try session.setMockJSON(User(id: 42, name: "Ada"))

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    ),
    session: session
)
```

`MockURLSession` and VCR replay mode are deterministic buffered test sessions.
They work with the 5 MiB `safeDefaults` response ceiling, which is checked
before cache insertion, interceptors, or decoding. Their fixture/cassette body
already exists in memory, so this test-only path does not model streaming peak
memory or early transport cancellation.

VCR record mode forwards to its backing session, so it fails closed with a
bounded streaming policy instead of silently buffering a live response. Use an
explicitly reviewed `.buffered(maxBytes:)` configuration while recording.
Core transport protocols are package implementation details in 5.0. Importing
this test-support product adds focused `DefaultNetworkClient` initializers for
``MockURLSession`` and ``VCRURLSession``; production code continues to inject a
concrete Foundation `URLSession`.

Use ``VCRRedactionPolicy`` before recording cassettes that may contain
credentials or personal data. Request bodies are represented by a SHA-256
digest, but response bodies remain part of the recorded cassette and must be
reviewed before committing fixtures.

## Topics

### URLSession test double

- ``MockURLSession``
- ``MockURLSessionResponse``

### Typed client stubs

- ``StubNetworkClient``
- ``StubRequestKey``
- ``StubBehavior``

### Record and replay

- ``VCRURLSession``
- ``VCRMode``
- ``VCRRedactionPolicy``
- ``VCRCassette``
- ``VCRInteraction``
- ``VCRRequest``
- ``VCRResponse``

### WebSocket assertions

- ``WebSocketEventRecorder``
