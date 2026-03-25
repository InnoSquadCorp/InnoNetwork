# ``InnoNetwork``

Type-safe networking for Apple platforms with explicit request modeling, transport policy, retry coordination, and request lifecycle observability.

## Overview

`InnoNetwork` is the core module of the package. It focuses on request execution and response decoding while keeping transport concerns visible instead of hiding them behind opaque convenience APIs.

Use this module when you need:

- typed request definitions with ``APIDefinition``
- a single async request entry point through ``DefaultNetworkClient``
- a public low-level typed execution hook through ``LowLevelNetworkClient/perform(executable:)``
- request encoding choices that stay explicit
- trust policy, retry policy, and observability that can be tuned when production needs it

The recommended starting point is ``NetworkConfiguration/safeDefaults(baseURL:)``. Reach for advanced configuration only when you have an operational reason to do so.

## Topics

### Essentials

- <doc:GettingStarted>
- ``DefaultNetworkClient``
- ``NetworkClient``
- ``LowLevelNetworkClient``
- ``APIDefinition``
- ``MultipartAPIDefinition``
- ``SingleRequestExecutable``
- ``ProtobufAPIDefinition``

### Configuration

- ``NetworkConfiguration``
- ``TrustPolicy``
- ``NetworkObservability``

### Request and Response Behavior

- ``HTTPMethod``
- ``ContentType``
- ``NetworkError``
