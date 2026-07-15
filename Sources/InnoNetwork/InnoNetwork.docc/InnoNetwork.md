# ``InnoNetwork``

Type-safe networking for Apple platforms with explicit request modeling, transport policy, retry coordination, and request lifecycle observability.

## Overview

`InnoNetwork` is the core module of the package. It focuses on request execution and response decoding while keeping transport concerns visible instead of hiding them behind opaque convenience APIs.

Model a named API catalog as explicit endpoint structs. The default-enabled
``APIDefinition(method:path:auth:)`` macro derives repetitive protocol
witnesses and validates the declaration, while each struct keeps its stored
inputs, `APIResponse`, and custom policy visible. Use ``EndpointBuilder`` for
one-off or runtime-composed requests.

Use this module when you need:

- typed request definitions with ``APIDefinition``
- a single async request entry point through ``DefaultNetworkClient``
- request encoding choices that stay explicit
- trust policy, retry policy, and observability that can be tuned when production needs it

Start prototypes and tests with ``NetworkConfiguration/safeDefaults(baseURL:)``.
For app-facing production clients, prefer
``NetworkConfiguration/recommendedForProduction(baseURL:)`` so retry,
circuit-breaker, idempotency-key, and body-size guardrails are enabled
explicitly. Reach for advanced configuration only when you have an operational
reason to tune those defaults.

## Topics

### Tutorials

- <doc:InnoNetwork-Tutorials>
- <doc:BuildAGitHubClient>

### Essentials

- <doc:GettingStarted>
- ``DefaultNetworkClient``
- ``NetworkClient``
- ``APIDefinition``
- <doc:UsingMacros>
- ``EndpointBuilder``
- ``MultipartAPIDefinition``

### Configuration

- ``NetworkConfiguration``
- ``TrustPolicy``
- <doc:TrustPolicies>
- ``NetworkEvent``
- ``NetworkEventObserving``
- ``NetworkMetricsReporting``

### Request and Response Behavior

- ``HTTPMethod``
- ``ContentType``
- ``NetworkError``
- ``NetworkErrorCategory``
- ``MultipartResponseDecoder``
- ``MultipartPart``
- ``DecodingInterceptor``
- <doc:DecodingInterceptorCookbook>
- <doc:ErrorClassification>
- <doc:OpenAPIGeneratorAdapter>
- <doc:OpenAPIGeneratorRecipe>
- <doc:ObservabilityExporters>

### Resilience

- ``RetryPolicy``
- ``ExponentialBackoffRetryPolicy``
- ``RefreshTokenPolicy``
- ``RequestCoalescingPolicy``
- ``ResponseCachePolicy``
- ``ResponseCache``
- ``InMemoryResponseCache``
- ``RequestExecutionPolicy``
- ``ResponseBodyBufferingPolicy``
- ``CircuitBreakerPolicy``
- ``CircuitBreakerOpenError``
- <doc:RetryDecisions>
- <doc:AuthRefresh>
- <doc:RequestSigning>
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
