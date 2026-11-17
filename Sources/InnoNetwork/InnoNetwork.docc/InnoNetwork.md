# ``InnoNetwork``

Type-safe networking for Apple platforms with explicit request modeling, transport policy, retry coordination, and request lifecycle observability.

Current stable baseline: **6.1.1** (Swift 6.2+, Apple platforms).
Use the published package tag and validate optional companion dependencies separately.

## Overview

`InnoNetwork` is the core module of the package. It focuses on request execution and response decoding while keeping transport concerns visible instead of hiding them behind opaque convenience APIs.

Model a named API catalog as explicit endpoint structs. The default-enabled
``APIDefinition(method:path:auth:)`` macro derives repetitive protocol
witnesses and validates the declaration, while each struct keeps its stored
inputs, `APIResponse`, and custom policy visible. Use ``EndpointBuilder`` for
one-off or runtime-composed requests.

Use this module when you need:

- typed request definitions with ``APIDefinition``
- a cancellable request handle with lifecycle events and an end-to-end
  deadline through ``NetworkOperation``
- one thrown error type, ``NetworkError``, with a payload-free
  ``NetworkErrorSummary`` for logs and view state
- request encoding choices that stay explicit
- trust policy, retry policy, and observability that can be tuned when production needs it

Start prototypes, tests, and ordinary production clients with
``NetworkConfiguration/safeDefaults(baseURL:)``. Reach for advanced
configuration only when the server contract or measured operations require a
specific retry, circuit-breaker, idempotency, cache, or observability policy.

``ResponseBodyBufferingPolicy/buffered(maxBytes:)`` performs post-buffer size
validation for inline requests: `URLSession.data(for:)` has already collected
the complete body before the limit is checked. Bounded
``ResponseBodyBufferingPolicy/streaming(maxBytes:)`` and bounded file-upload
responses validate while bytes arrive and explicitly cancel the underlying
task when the ceiling is exceeded. A bounded file upload uses a streamed data
task with an explicit `Content-Length`; an explicitly unbounded file upload
uses the native file-backed upload task.

Core URLSession transports enforce redirect policy and URL admission per hop.
On cross-origin redirects they also clear values configured through
`URLSessionConfiguration.httpAdditionalHeaders`, preventing Foundation from
restoring a session default after the policy removes it. Same-origin redirects
retain those values.

## Topics

### Tutorials

- <doc:InnoNetwork-Tutorials>
- <doc:BuildAGitHubClient>

### Essentials

- <doc:GettingStarted>
- <doc:MigrationTo7>
- <doc:MigrationTo6>
- ``DefaultNetworkClient``
- ``APIDefinition``
- <doc:UsingMacros>
- ``NetworkError``

### Operation Handles

- ``NetworkOperation``
- ``NetworkOperationEvent``
- ``NetworkOperationReplaySafety``
- ``NetworkOperationDeadline``
- ``NetworkOperationDeadlineStage``

### Error Model

- <doc:ErrorClassification>
- ``NetworkErrorCategory``
- ``NetworkErrorCode``
- ``NetworkErrorSummary``
- ``NetworkRecoveryDisposition``
- ``NetworkPolicyRejection``
- ``NetworkAuthenticationFailure``

### More Request Shapes

- ``NetworkClient``
- ``UploadNetworkClient``
- ``EndpointBuilder``
- ``MultipartAPIDefinition``
- <doc:StreamingGuide>
- ``StreamingAPIDefinition``
- ``StreamingResumePolicy``
- ``ServerSentEventDecoder``
- ``BoundedNetworkTransfer``
- ``NetworkRetryExecutor``
- ``NetworkURLValidator``

### Configuration

- ``NetworkConfiguration``
- ``TrustPolicy``
- <doc:TrustPolicies>
- ``NetworkEvent``
- ``NetworkEventObserving``
- ``SemanticNetworkEventAdapter``
- ``NetworkMetricsReporting``
- ``NetworkSpanObserver``
- ``NetworkSpanExporting``
- <doc:AdmissionAndRateLimiting>

### Request and Response Behavior

- ``HTTPMethod``
- ``ContentType``
- ``MultipartResponseDecoder``
- ``MultipartPart``
- ``DecodingInterceptor``
- <doc:DecodingInterceptorCookbook>
- <doc:OpenAPIGeneratorAdapter>
- <doc:OpenAPIGeneratorRecipe>
- <doc:ObservabilityExporters>

### Resilience

- ``RetryPolicy``
- ``ExponentialBackoffRetryPolicy``
- ``RefreshTokenPolicy``
- ``AuthenticationRealm``
- ``RequestCoalescingPolicy``
- ``ResponseCachePolicy``
- ``ResponseCache``
- ``InMemoryResponseCache``
- ``RequestExecutionPolicy``
- ``RateLimitExecutionPolicy``
- ``RequestAdmissionPolicy``
- ``AdvancedRateLimitPolicy``
- ``ResponseBodyBufferingPolicy``
- ``CircuitBreakerPolicy``
- ``CircuitBreakerOpenError``
- <doc:RetryDecisions>
- <doc:AuthRefresh>
- <doc:RequestSigning>
- <doc:RequestCredentials>
- <doc:OfflineHandling>
- <doc:CachingStrategies>
- <doc:AppNetworkingCookbook>
- <doc:MigrationFromAlamofire>

### Event Pipeline

- <doc:EventDeliveryGuide>
- ``EventDeliveryPolicy``
- ``EventPipelineOverflowPolicy``
- ``EventPipelineMetricsReporting``
- ``EventPipelineAggregateSnapshotMetric``

### OpenAPI Integration

- <doc:OpenAPIRuntimeClientTransport>

### 한국어 문서 (Korean translations)

- <doc:GettingStarted-ko>
- <doc:Auth-ko>
- <doc:ErrorHandling-ko>
