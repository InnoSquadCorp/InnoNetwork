# Custom Headers Examples

This example demonstrates how to add and customize HTTP headers in your network requests.

## Setup

```swift
import InnoNetwork

struct MyAPI: APIConfigure {
    var host: String { "httpbin.org" }
    var basePath: String { "" }
}

API.configure(MyAPI())
```

## Header Types

InnoNetwork provides convenient constructors for common HTTP headers:

- `HTTPHeader.authorization(username:password:)` - Basic authentication
- `HTTPHeader.authorization(bearerToken:)` - Bearer token authentication
- `HTTPHeader.contentType(_:)` - Content-Type header
- `HTTPHeader.accept(_:)` - Accept header
- `HTTPHeader.acceptLanguage(_:)` - Accept-Language header
- `HTTPHeader.acceptEncoding(_:)` - Accept-Encoding header
- `HTTPHeader.userAgent(_:)` - User-Agent header

Note: We use httpbin.org (https://httpbin.org) for testing headers as it echoes back to request headers.

## Running the Examples

```bash
# From the InnoNetwork directory
cd Examples/CustomHeaders
swift CustomHeadersExample.swift
```

## Covered Scenarios

1. **Basic Authentication**: Using username/password credentials
2. **Bearer Token Authentication**: Using bearer token
3. **Custom Content-Type**: Setting custom content type
4. **Custom User-Agent**: Custom user agent string
5. **Multiple Custom Headers**: Multiple headers in one request
6. **Accept-Language Header**: Language preference
7. **Accept-Encoding Header**: Encoding preference

## Basic Pattern

Define custom headers in your API definition:

```swift
actor MyAPIRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Response

    var method: HTTPMethod { .get }
    var path: String { "/endpoint" }

    var headers: HTTPHeaders {
        var customHeaders = HTTPHeaders.default
        customHeaders.add(.authorization(bearerToken: "my-token"))
        customHeaders.add(.accept("application/json"))
        return customHeaders
    }

    var configuration: NetworkConfiguration? {
        NetworkConfiguration(baseURL: URL(string: "https://api.example.com")!)
    }
}
```

## Common Header Patterns

### Authentication

```swift
var headers: HTTPHeaders {
    var authHeaders = HTTPHeaders.default
    authHeaders.add(.authorization(bearerToken: "your-token"))
    return authHeaders
}
```

### Content Negotiation

```swift
var headers: HTTPHeaders {
    var contentHeaders = HTTPHeaders.default
    contentHeaders.add(.accept("application/vnd.api+json"))
    contentHeaders.add(.acceptLanguage("ko-KR,ko;q=0.9,en-US;q=0.8"))
    return contentHeaders
}
```

### Custom Headers

```swift
var headers: HTTPHeaders {
    var customHeaders = HTTPHeaders([
        "X-Request-ID": UUID().uuidString,
        "X-Client-Version": "1.0.0",
        "X-Device-ID": "device-123"
    ])

    customHeaders.add(.userAgent("MyApp/1.0"))
    return customHeaders
}
```
