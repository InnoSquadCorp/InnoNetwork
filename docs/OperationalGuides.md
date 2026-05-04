# Operational Guides

## Low-Level SPI

Use `@_spi(GeneratedClientSupport)` only when adapting a generated client or SDK
wrapper that cannot be represented with `APIDefinition`, `MultipartAPIDefinition`,
or `StreamingAPIDefinition`. App feature code should stay on the public endpoint
protocols so it inherits the 4.x stability contract.

## Cookie Isolation

`URLSessionConfiguration.default` can share process-level cookie state. Apps that
operate multiple tenants or SDK accounts should create a dedicated
`URLSessionConfiguration`, assign an isolated `HTTPCookieStorage`, then pass the
resulting `URLSession` to `DefaultNetworkClient`.

## URLSession Lifecycle

Prefer one long-lived `DefaultNetworkClient` per feature boundary or API domain.
Avoid creating a new client for every request. If a client owns a custom
`URLSession`, invalidate that session when the feature/session scope ends.

## Low Data Mode and Expensive Networks

Core requests expose configuration-level and endpoint-level overrides for:

- `allowsCellularAccess`
- `allowsExpensiveNetworkAccess`
- `allowsConstrainedNetworkAccess`

Keep all three enabled for foreground user actions. Disable constrained or
expensive access for background prefetch, large sync, or non-urgent telemetry.

## Large Multipart Uploads

`MultipartUploadStrategy.platformDefault` spills large bodies to a temporary file
before upload. This keeps peak memory bounded but performs synchronous file
materialization before transport dispatch. For large media endpoints, prefer
`.alwaysStream` and observe the `multipart_spilled_to_disk` OSLog event while
tuning thresholds.

## Streaming Consumers

`stream(_:)` remains lossless and uses unbounded output buffering. High-volume
streams whose consumers can tolerate dropped decoded values should use
`stream(_:bufferingPolicy:)` with `.bufferingNewest(_:)` or
`.bufferingOldest(_:)` to cap memory.

## Local CPU Notes

DocC, symbol graph extraction, and benchmark jobs are CPU-heavy. Run them
sequentially on local machines and avoid running the same jobs for sibling
Swift packages at the same time.
