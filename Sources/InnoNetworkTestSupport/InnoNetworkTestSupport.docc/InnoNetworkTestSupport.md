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

URL user-info and fragments are always removed from VCR request identities
and mismatch diagnostics, independently of the configurable query/header
redaction policy. The backing transport still receives the original request.

When constructing a ``VCRURLSession`` with a legacy cassette, its request URLs
are normalized in memory without changing response bodies or replay order.
The caller's cassette value and existing file remain unchanged. To migrate a
reviewed fixture, load it, construct the session, and write `session.cassette`
to a new file before replacing the old fixture. Loading/writing a raw
``VCRCassette`` alone does not sanitize it. Remove old credential-bearing
fixtures from distribution and rotate real credentials if they were exposed.

User-info and fragments no longer distinguish otherwise identical requests.
Use separate cassettes for distinct authentication scenarios; sequential
replay still consumes exactly the next matching interaction. Query redaction
and response-body review remain the caller's responsibility.

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
