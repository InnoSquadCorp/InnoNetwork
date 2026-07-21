# Apple swift-openapi-generator integration (5.x)

InnoNetwork 5.x provides two OpenAPI runtime
paths. They are complementary, but they do not provide the same execution
behavior. Choose the entry point whose types your application already owns.

## Selection guide

| Entry point | Adapter | Execution path | Choose when |
| --- | --- | --- | --- |
| A generated or hand-written operation descriptor | `OpenAPIRestOperation` + `OpenAPIRequest` | `DefaultNetworkClient` full pipeline | The operation can expose InnoNetwork method, path, parameters, response, headers, status codes, and transport policy. |
| An `apple/swift-openapi-generator` `Client` | `InnoNetworkClientTransport` | Caller-supplied `URLSession` only | The generated `Client` and `OpenAPIRuntime.ClientTransport` contract must remain the entry point. |

The root package resolves `swift-openapi-runtime` for the optional
`InnoNetworkOpenAPI` product. This is a runtime dependency, not the generator
build plugin. `Tools/openapi-to-innonetwork` remains a separate package and its
Yams dependency is not part of the root dependency graph.

## Full InnoNetwork pipeline with `OpenAPIRequest`

`OpenAPIRestOperation` describes an operation using InnoNetwork's request
shape. Wrap a conforming generated or hand-written descriptor in
`OpenAPIRequest` and dispatch it through `DefaultNetworkClient`:

```swift
let operation = GetProfileOperation(userID: userID)
let response = try await networkClient.request(OpenAPIRequest(operation))
```

This path inherits the full pipeline configured on the client, including
request interceptors and signers, retry, request coalescing, response cache,
circuit breaker, observability, redirect handling, and trust evaluation.

`OpenAPIRestOperation` is an InnoNetwork bridge protocol. Arbitrary
`swift-openapi-generator` output does not conform to it automatically; add a
small operation adapter when you want this path.

## Generated `Client` with `InnoNetworkClientTransport`

`InnoNetworkClientTransport` conforms to
`OpenAPIRuntime.ClientTransport`. Supply the `URLSession` whose session-level
behavior the application owns, then pass the transport to the generated
client:

```swift
let session = URLSession(configuration: .ephemeral)
let transport = InnoNetworkClientTransport(session: session)
let client = Client(serverURL: serverURL, transport: transport)
```

The transport translates `HTTPRequest` and `HTTPBody` directly to a
`URLRequest`, sends it through that session, and translates the response back
to OpenAPI runtime types. It deliberately does **not** dispatch through
`DefaultNetworkClient`, so this path does not inherit InnoNetwork retry, auth
refresh, interceptors, signing, response cache, request coalescing, circuit
breaker, redirect policy, observability, or trust-policy evaluation.

Configure timeout, URL cache, cookie storage, connectivity, HTTP/3, and
delegate-owned behavior on the supplied `URLSession`. If you derive its
configuration from `NetworkConfiguration.makeURLSessionConfiguration()`, only
the resulting URLSession-level values carry over; asynchronous InnoNetwork
pipeline policy does not.

## Body and response behavior

- Outgoing `HTTPBody` values are collected before dispatch, with a default
  `requestBodyByteLimit` of 50 MiB.
- Incoming response bodies stream back to the generated client, with a default
  `responseBodyByteLimit` of 50 MiB.
- Both limits can be overridden in the transport initializer.
- Status-code interpretation remains owned by the generated client. The
  transport converts the Foundation response to `HTTPResponse` and does not
  apply an `APIDefinition.acceptableStatusCodes` policy.
- Responses to HEAD requests and responses with `1xx`, `204`, `205`, or `304`
  status return no body.

Choose another transport for payloads that cannot be collected within the
outgoing limit or for flows that require a specialized streaming upload.

## Relationship to `Tools/openapi-to-innonetwork`

The local tool emits `APIDefinition` conformers for a deliberately narrow
OpenAPI subset. Those requests already use the full `DefaultNetworkClient`
pipeline and do not need `InnoNetworkClientTransport`.

Use `swift-openapi-generator` plus `InnoNetworkClientTransport` when its
broader schema and generated-client surface are more important than the
InnoNetwork policy pipeline. Use a custom `OpenAPIRestOperation` adapter when
you need both richer generated models and full InnoNetwork execution behavior.
