# Error Handling Examples

This example demonstrates how to handle the errors that can occur during
network requests. `NetworkError` is the only error type the library throws:
`client.request(_:)`, `client.upload(_:)`, and `NetworkOperation.value()` all
throw it, so one handler covers every call shape.

## Setup

```swift
import InnoNetwork

let configuration = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)
let client = DefaultNetworkClient(configuration: configuration)
```

## Error Types

`NetworkError` has ten cases. Each carries the structured information needed
to decide on recovery.

| Case | Meaning | Usually transient |
| --- | --- | --- |
| `.configuration(reason:)` | Invalid base URL, invalid request shape, invalid encoded payload, or an offline preflight rejection. | No |
| `.statusCode(Response)` | HTTP status code outside the configured acceptable range. | `408`, `429`, and `5xx` only |
| `.decoding(stage:underlying:response:)` | A response failed to decode at a specific `DecodingStage`. | No |
| `.underlying(_, Response?)` | A transport error the built-in mapper did not classify, or a `304` that cannot be reconciled with the stored response. | Yes |
| `.reachability(_, _, Response?)` | DNS, offline, dropped-connection, or unavailable-cellular-data failure (`ReachabilityReason`). | Yes |
| `.trustEvaluationFailed(_)` | TLS pinning or trust evaluation failure. | No |
| `.cancelled` | The request was cancelled. | No |
| `.timeout(reason:underlying:)` | Request, resource, or connection timeout, or an expired operation deadline. | Yes |
| `.policyRejected(NetworkPolicyRejection)` | A locally configured policy declined the exchange: response over the body limit, open circuit breaker, full rate-limit or admission queue, or a response that is not HTTP. | No |
| `.authentication(NetworkAuthenticationFailure)` | The session cannot be renewed, or a named request credential could not be selected, acquired, or applied. | No |

Two cases describe failures the library decides locally:

- **`.policyRejected`** says nothing about the server's health, and repeating
  the same request immediately gives the same result. The built-in retry
  policy never retries it and the circuit breaker never counts it.
- **`.authentication`** means the request could not be authenticated.
  Replaying it cannot repair the session, so it is never retried. A `401`
  that the server returns after a successful refresh stays `.statusCode`.

`.underlying` carries transport errors the built-in mapper did not classify,
and one library-generated failure: a `304 Not Modified` that cannot be
reconciled with the stored response, with domain `InnoNetwork.ResponseCache`
and code `304`. The library removes that stored entry first, so a retry
receives a full response. No local policy rejection or authentication failure
uses `.underlying`, so there is no other domain or numeric code to compare.

## Classify Before You Switch

Most call sites do not need every payload. Three helpers answer the common
questions:

| Helper | Answers |
| --- | --- |
| `error.category` | Which coarse bucket is this? (`NetworkErrorCategory`: `.configuration`, `.statusCode`, `.decoding`, `.transport`, `.reachability`, `.trust`, `.cancellation`, `.timeout`, `.policy`, `.authentication`) |
| `error.isRetriableHint` | Is this error class usually transient? It is `false` for `.policyRejected` and `.authentication`. It does not override the client's `RetryPolicy`. |
| `error.isUserVisible` | Is this worth showing to the user? Cancellation and programmer errors are not. |

```swift
func suggestedAction(for error: NetworkError) -> String {
    switch error.category {
    case .configuration:
        return "Fix the request or the client configuration"
    case .statusCode:
        return error.isRetriableHint ? "Try again later" : "Show the server's answer"
    case .decoding:
        return "Report a response format mismatch"
    case .transport, .timeout:
        return "Offer a retry"
    case .reachability:
        return "Wait for a connection, then offer a retry"
    case .trust:
        return "Stop: the connection is not trusted"
    case .cancellation:
        return "Nothing to do"
    case .policy:
        return "Do not retry: a local policy rejected the exchange"
    case .authentication:
        return "Ask the user to sign in again"
    }
}
```

A `switch` over `NetworkErrorCategory` without `default` must list `.policy`
and `.authentication`.

## Matching Every Case

```swift
do {
    let response = try await client.request(MyAPIRequest())
    print("Success: \(response)")
} catch {
    switch error {
    case .configuration(let reason):
        switch reason {
        case .invalidBaseURL(let message):
            print("Invalid Base URL: \(message)")
        case .invalidRequest(let message):
            print("Invalid Request: \(message)")
        case .invalidPayload:
            print("Invalid Payload: request encoding or validation failed")
        case .offline(let message):
            print("Offline: \(message)")
        }
    case .statusCode(let response):
        print("Status Code Error: \(response.statusCode)")
        if response.statusCode == 404 {
            print("→ Resource not found")
        } else if response.statusCode >= 500 {
            print("→ Server error")
        } else if response.statusCode >= 400 {
            print("→ Client error")
        }
    case .decoding(let stage, let decodingError, let response):
        print("Decoding Error (\(stage)): \(decodingError)")
        print("Status Code: \(response.statusCode)")
    case .underlying(let underlyingError, let response):
        print("Underlying Error: \(underlyingError)")
        if let response = response {
            print("Status Code: \(response.statusCode)")
        }
    case .reachability(let reason, let underlyingError, let response):
        print("Reachability Error: \(reason)")
        print("Underlying Error: \(underlyingError)")
        if let response = response {
            print("Status Code: \(response.statusCode)")
        }
    case .trustEvaluationFailed(let reason):
        print("Trust Evaluation Failed: \(reason)")
    case .cancelled:
        print("Request Cancelled")
    case .timeout(let reason, let underlying):
        print("Timeout: \(reason), underlying: \(String(describing: underlying))")
    case .policyRejected(let rejection):
        print("Policy Rejection: \(rejection)")
    case .authentication(let failure):
        print("Authentication Failure: \(failure)")
    @unknown default:
        print("Unhandled NetworkError: \(error)")
    }
}
```

`NetworkError` is not `@frozen`. Keep `@unknown default` at the end of a
switch that lists every case, so a case added later is reported by the
compiler instead of failing the build.

## Policy Rejections

Match the payload when the reason matters. A response over the configured body
limit carries the limit and the observed size:

```swift
let boundedClient = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://jsonplaceholder.typicode.com")!,
        resilience: ResiliencePack(bodyBuffering: .streaming(maxBytes: 64))
    )
)

do {
    let post = try await boundedClient.request(ValidRequest())
    print("Success: \(post.title)")
} catch NetworkError.policyRejected(.responseBodyLimitExceeded(let limitBytes, let observedBytes)) {
    print("Response too large: observed \(observedBytes) bytes, limit \(limitBytes) bytes")
} catch {
    print("Other failure: \(error)")
}
```

| `NetworkPolicyRejection` | Stable code |
| --- | --- |
| `.responseBodyLimitExceeded(limitBytes:observedBytes:)` | `4003` |
| `.circuitOpen(CircuitBreakerOpenError)` | `4011` |
| `.rateLimitQueueFull` | `4008` |
| `.rateLimitScopeLimitReached` | `4009` |
| `.admissionQueueFull` | `4006` |
| `.admissionWaitExpired` | `4007` |
| `.nonHTTPResponse` | `3002` |

## Authentication Failures

```swift
func handleAuthentication(_ error: NetworkError) {
    guard case .authentication(let failure) = error else { return }
    switch failure {
    case .refreshFailed(let cause):
        // The session cannot be renewed. Ask the user to sign in again.
        print("Session refresh failed: \(cause.message)")
    case .credential(let reason):
        // `reason` is a secret-free RequestSecurityFailure.
        print("Request credential failed: \(reason)")
    }
}
```

`.refreshFailed` means the session cannot be renewed: the refresh request was
rejected with a status that is not transient (such as `400 invalid_grant` or
`401`) or with a credential-rejection `URLError` such as
`.userAuthenticationRequired`, the token response could not be decoded, or the
refresh closure threw an error of its own type. A refresh that failed for a
reason that says nothing about the session keeps its own case, because the
session may still be valid: cancellation, a connectivity failure, a timeout, a
`408`, `429`, or `5xx` from the refresh endpoint (`.statusCode` then carries
the refresh endpoint's response), an unclassified transport error, a
configuration failure including an offline device, a policy rejection, or a
trust failure. Those follow the ordinary retry rules. The rule is the same for
the proactive refresh of a request that has no token yet and for the replay
after a `401`.

## A Payload-Free Summary

`error.summary` returns a `NetworkErrorSummary`: the category, the stable
numeric code, the HTTP status, and a recommended recovery. It carries no
response body, headers, URL, or underlying error text, so it is safe to store
in view state, compare in tests, or send to analytics.

```swift
do {
    let post = try await client.request(NotFoundRequest())
    print("Success: \(post.title)")
} catch {
    let summary = error.summary
    print("category=\(summary.category) code=\(summary.code) status=\(String(describing: summary.statusCode))")
}
```

`error.summary` has no request context, so it never recommends a replay. An
operation handle knows the request's method, authentication, and replay
safety, and its summary can recommend one:

```swift
let operation = client.start(NotFoundRequest())
do {
    let post = try await operation.value()
    print("Success: \(post.title)")
} catch {
    let summary = await operation.failureSummary() ?? error.summary
    switch summary.recovery {
    case .retry: print("Offer a retry, within your own attempt budget")
    case .waitForConnectivity: print("Wait for connectivity")
    case .reauthenticate: print("Ask the user to sign in again")
    case .doNotRetry: print("Do not retry")
    case .none: print("Nothing to do")
    }
}
```

Outside an operation, `error.summary(method:authentication:replaySafety:)`
gives the same contextual form.

## Accessing Response Data from Errors

```swift
do {
    let post = try await client.request(NotFoundRequest())
    print("Success: \(post.title)")
} catch {
    // Access response data if available
    if let response = error.response {
        print("Status Code: \(response.statusCode)")
        print("Response Data Length: \(response.data.count)")

        // Try to decode error response
        if let jsonString = String(data: response.data, encoding: .utf8) {
            print("Response Body: \(jsonString)")
        }
    }
    print("Error Description: \(error.localizedDescription)")
}
```

## Covered Scenarios

The numbers match the `Example N` comments in `ErrorHandlingExample.swift`:

1. **Basic Error Handling**: Do-catch pattern for a `404`
2. **Invalid Request**: Handling a request configuration failure
3. **Successful Request**: Handling a successful response
4. **Error with Response Data**: Accessing response data from an error
5. **POST Request**: Handling a POST request
6. **Cancellation Handling**: Handling a cancelled request
7. **Category-Driven Handling**: `category`, `isRetriableHint`, `isUserVisible`
8. **Policy Rejection**: A response over a 64-byte body limit
9. **Authentication Failure**: Matching `.refreshFailed` and `.credential`
10. **Error Summary**: `error.summary` and `operation.failureSummary()`
11. **Classification Table**: Category, code, and recovery of sample errors,
    including an authentication failure, without using the network

## Validating the Examples

From the repository root, maintainers can compile the copyable source against
the current package with:

```bash
bash Scripts/check_stable_examples.sh
```

To execute the live scenarios, copy `ErrorHandlingExample.swift` into an app
or executable target that depends on InnoNetwork.
