# Error Handling Examples

This example demonstrates how to handle various errors that can occur during network requests.

## Setup

```swift
import InnoNetwork

struct MyAPI: APIConfigure {
    var host: String { "jsonplaceholder.typicode.com" }
    var basePath: String { "" }
}

API.configure(MyAPI())
```

## Error Types

InnoNetwork provides the following error types:

- `NetworkError.invalidBaseURL`: Invalid base URL configuration
- `NetworkError.jsonMapping`: Failed to parse JSON response
- `NetworkError.statusCode`: HTTP status code outside 200-299 range
- `NetworkError.objectMapping`: Failed to map response to Decodable object
- `NetworkError.nonHTTPResponse`: Response is not HTTPURLResponse
- `NetworkError.underlying`: Underlying network error (URLError, etc.)
- `NetworkError.undefined`: Undefined error
- `NetworkError.cancelled`: Request was cancelled

## Running the Examples

To run these examples:

```bash
swift ErrorHandlingExample.swift
```

## Covered Scenarios

1. **Basic Error Handling**: Do-catch pattern for network errors
2. **Invalid URL**: Handling invalid base URLs
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
} catch let error as NetworkError {
    switch error {
    case .invalidBaseURL(let urlString):
        print("Invalid Base URL: \(urlString)")
    case .jsonMapping(let response):
        print("JSON Mapping Error")
        print("Status Code: \(response.statusCode)")
    case .statusCode(let response):
        print("Status Code Error: \(response.statusCode)")
        if response.statusCode == 404 {
            print("→ Resource not found")
        } else if response.statusCode >= 500 {
            print("→ Server error")
        } else if response.statusCode >= 400 {
            print("→ Client error")
        }
    case .objectMapping(let decodingError, let response):
        print("Object Mapping Error: \(decodingError)")
        print("Status Code: \(response.statusCode)")
    case .nonHTTPResponse(let response):
        print("Non-HTTP Response: \(response)")
    case .underlying(let underlyingError, let response):
        print("Underlying Error: \(underlyingError)")
        if let response = response {
            print("Status Code: \(response.statusCode)")
        }
    case .undefined:
        print("Undefined Error")
    case .cancelled:
        print("Request Cancelled")
    }
} catch {
    print("Unknown error: \(error)")
}
```

## Accessing Response Data from Errors

```swift
do {
    let post = try await client.request(NotFoundRequest())
    print("Success: \(post.title)")
} catch let error as NetworkError {
    // Access response data if available
    if let response = error.response {
        print("Status Code: \(response.statusCode)")
        print("Response Data Length: \(response.data.count)")

        // Try to decode error response
        if let jsonString = String(data: response.data, encoding: .utf8) {
            print("Response Body: \(jsonString)")
        }
    }
    print("Error Description: \(error.localizedDescription))
}
```

## Running the Examples

```bash
# From the InnoNetwork directory
cd Examples/ErrorHandling
swift ErrorHandlingExample.swift
```

This will execute all error handling scenarios and show how each error type is handled.
