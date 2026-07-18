# Error Handling Examples

This example demonstrates how to handle various errors that can occur during network requests.

## Setup

```swift
import InnoNetwork

let configuration = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)
```

## Error Types

InnoNetwork provides the following error families:

- `NetworkError.configuration(reason:)`: Invalid base URL, invalid request
  shape, or an offline preflight rejection.
- `NetworkError.statusCode`: HTTP status code outside the configured
  acceptable range.
- `NetworkError.decoding`: Failed to decode a response at a specific
  `DecodingStage`.
- `NetworkError.underlying`: Underlying transport or adapter error
  (also surfaces the rare non-`HTTPURLResponse` path with code `3002`).
- `NetworkError.reachability`: DNS, offline, or dropped-connection failure.
- `NetworkError.trustEvaluationFailed`: TLS pinning or trust evaluation failure.
- `NetworkError.cancelled`: Request was cancelled.
- `NetworkError.timeout`: Request, resource, or connection timeout.

## Validating the Examples

From the repository root, maintainers can compile the copyable source against
the current package with:

```bash
bash Scripts/check_stable_examples.sh
```

To execute the live scenarios, copy `ErrorHandlingExample.swift` into an app
or executable target that depends on InnoNetwork.

## Covered Scenarios

1. **Basic Error Handling**: Do-catch pattern for network errors
2. **Invalid Request**: Handling request configuration failures
3. **Not Found**: Handling 404 errors
4. **Successful Request**: Handling successful responses
5. **Error with Response Data**: Accessing response data from errors
6. **POST Request**: Handling POST requests with errors
7. **Cancellation Handling**: Handling cancelled requests

## Basic Error Handling Pattern

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
    @unknown default:
        print("Unhandled NetworkError: \(error)")
    }
}
```

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
