# Platform-native packages

InnoNetwork keeps one repository and one behavioral identity while preserving
each runtime's native transport and package manager.

| Platform | Distribution | Native boundary | Status |
| --- | --- | --- | --- |
| Apple | SwiftPM package at the repository root | `URLSession` / `URLRequest` | 6.1.1 stable; root source follows `main` |
| Android | [`Platforms/Android`](Android) | OkHttp `Request`, `Response`, and `Call.Factory` | 1.0.0 release candidate |
| Web / React | [`Platforms/Web`](Web) | Fetch `Request`, `Response`, and `AbortSignal` | 1.0.0 release candidate |

The packages share observable contracts rather than pretending their types or
feature sets are identical:

- HTTP status codes are response values until a caller explicitly rejects them.
- cancellation reaches the active native transport;
- buffered response bodies have a conservative default ceiling and an explicit
  streaming escape hatch;
- native request configuration remains available for TLS, cache, cookies,
  interceptors, credentials, CORS, and CSP;
- typed endpoint/client layers are optional above the native session;
- JSON decoding requires an explicit serializer or runtime validator;
- transport, decoding, and policy errors omit credentials, query values, and
  response bodies from messages.

Cross-platform 1.0 currently aligns the low-level session, typed client, bounded
buffering, status, cancellation, and explicit JSON boundaries. The root Swift
package's authentication, retries, circuit breaker, request coalescing,
operation handles, persistent cache, upload/download, WebSocket, OpenAPI, trust,
AWS, and test-support products are not claimed as Android/Web parity.

See [`docs/CrossPlatformArchitecture.md`](../docs/CrossPlatformArchitecture.md)
for layering and code-generation policy, and
[`Platforms/API_STABILITY.md`](API_STABILITY.md) for compatibility and release
gates. `Scripts/check_cross_platform.sh` exercises the Android Maven consumer,
the real Web tarball, independent TypeScript and React consumers, and all local
release-candidate checks. Chromium runtime validation is available through
`npm --prefix Platforms/Web run test:browser` and runs in CI.

The [ecosystem fit assessment](ECOSYSTEM_FIT.md) records Android and React
integration decisions and unqualified framework/toolchain boundaries.
The current [release readiness record](RELEASE_READINESS.md) lists fresh checks,
remaining qualifications, and the 1.0.0 scope. To create an installable local
Maven/npm bundle after all portable gates pass, run
`bash Scripts/prepare_cross_platform_release.sh` from the repository root.

[Native layout and releasing](RELEASING.md) fixes the SwiftPM root, independent
Gradle/npm package roots, consumer paths and separate release/tag boundaries.
The layout and its negative controls are checked by the portable gate and CI.
