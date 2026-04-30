//
//  CustomHeadersExample.swift
//  InnoNetwork Examples
//
//  This file demonstrates how to add custom HTTP headers to requests.
//  Shows various header types and usage patterns.
//

import Foundation
import InnoNetwork

// MARK: - 1. Client Configuration

private let clientConfiguration = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://httpbin.org")!
)

// MARK: - 2. Data Models

struct HeadersResponse: Decodable {
    let headers: [String: String]
}

// MARK: - 3. API Definitions with Custom Headers

// Example 1: Basic Authentication
actor BasicAuthRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = HeadersResponse

    var method: HTTPMethod { .get }
    var path: String { "/headers" }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.authorization(username: "user", password: "pass"))
        return defaultHeaders
    }
}

// Example 2: Bearer Token Authentication
actor BearerTokenRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = HeadersResponse

    let token: String

    var method: HTTPMethod { .get }
    var path: String { "/headers" }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.authorization(bearerToken: token))
        return defaultHeaders
    }

    init(token: String) {
        self.token = token
    }
}

// Example 3: Custom Content-Type
actor CustomContentTypeRequest: APIDefinition {
    struct BodyParameter: Encodable {
        let message: String
    }

    typealias Parameter = BodyParameter
    typealias APIResponse = HeadersResponse

    let parameters: BodyParameter?

    var method: HTTPMethod { .post }
    var path: String { "/headers" }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.contentType("application/vnd.api+json"))
        return defaultHeaders
    }

    init(message: String) {
        self.parameters = BodyParameter(message: message)
    }
}

// Example 4: Custom User-Agent
actor CustomUserAgentRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = HeadersResponse

    var method: HTTPMethod { .get }
    var path: String { "/headers" }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.userAgent("MyApp/1.0.0 (iOS)"))
        return defaultHeaders
    }
}

// Example 5: Multiple Custom Headers
actor MultipleHeadersRequest: APIDefinition {
    struct PostData: Encodable {
        let key: String
        let value: String
    }

    typealias Parameter = PostData
    typealias APIResponse = HeadersResponse

    let parameters: PostData?

    var method: HTTPMethod { .post }
    var path: String { "/headers" }

    var headers: HTTPHeaders {
        var customHeaders = HTTPHeaders([
            "X-Custom-Header": "CustomValue",
            "X-Request-ID": UUID().uuidString,
            "X-Client-Version": "1.0.0",
        ])

        customHeaders.add(.authorization(bearerToken: "sample-token"))
        customHeaders.add(.accept("application/json"))
        customHeaders.add(.userAgent("InnoNetworkExample/1.0"))

        return customHeaders
    }

    init(key: String, value: String) {
        self.parameters = PostData(key: key, value: value)
    }
}

// Example 6: Accept-Language Header
actor AcceptLanguageRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = HeadersResponse

    var method: HTTPMethod { .get }
    var path: String { "/headers" }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.acceptLanguage("ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7"))
        return defaultHeaders
    }
}

// Example 7: Accept-Encoding Header
actor AcceptEncodingRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = HeadersResponse

    var method: HTTPMethod { .get }
    var path: String { "/headers" }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.acceptEncoding("gzip, deflate, br"))
        return defaultHeaders
    }
}

// MARK: - 4. Usage Examples

actor CustomHeadersExample {
    let client: DefaultNetworkClient

    init() {
        self.client = DefaultNetworkClient(configuration: clientConfiguration)
    }

    // Example 1: Basic Authentication
    func basicAuthExample() async {
        print("=== Example 1: Basic Authentication ===")
        do {
            let response = try await client.request(BasicAuthRequest())
            print("✅ Success!")
            if let authHeader = response.headers["Authorization"] {
                print("Authorization Header: \(authHeader)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Example 2: Bearer Token Authentication
    func bearerTokenExample() async {
        print("\n=== Example 2: Bearer Token ===")
        do {
            let response = try await client.request(BearerTokenRequest(token: "my-bearer-token-12345"))
            print("✅ Success!")
            if let authHeader = response.headers["Authorization"] {
                print("Authorization Header: \(authHeader)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Example 3: Custom Content-Type
    func customContentTypeExample() async {
        print("\n=== Example 3: Custom Content-Type ===")
        do {
            let response = try await client.request(CustomContentTypeRequest(message: "Hello"))
            print("✅ Success!")
            if let contentType = response.headers["Content-Type"] {
                print("Content-Type Header: \(contentType)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Example 4: Custom User-Agent
    func customUserAgentExample() async {
        print("\n=== Example 4: Custom User-Agent ===")
        do {
            let response = try await client.request(CustomUserAgentRequest())
            print("✅ Success!")
            if let userAgent = response.headers["User-Agent"] {
                print("User-Agent Header: \(userAgent)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Example 5: Multiple Custom Headers
    func multipleHeadersExample() async {
        print("\n=== Example 5: Multiple Custom Headers ===")
        do {
            let response = try await client.request(MultipleHeadersRequest(key: "test", value: "value"))
            print("✅ Success!")
            print("All Headers:")
            for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) {
                print("  \(key): \(value)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Example 6: Accept-Language Header
    func acceptLanguageExample() async {
        print("\n=== Example 6: Accept-Language Header ===")
        do {
            let response = try await client.request(AcceptLanguageRequest())
            print("✅ Success!")
            if let acceptLanguage = response.headers["Accept-Language"] {
                print("Accept-Language Header: \(acceptLanguage)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Example 7: Accept-Encoding Header
    func acceptEncodingExample() async {
        print("\n=== Example 7: Accept-Encoding Header ===")
        do {
            let response = try await client.request(AcceptEncodingRequest())
            print("✅ Success!")
            if let acceptEncoding = response.headers["Accept-Encoding"] {
                print("Accept-Encoding Header: \(acceptEncoding)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Run all examples
    func runAllExamples() async {
        await basicAuthExample()
        await bearerTokenExample()
        await customContentTypeExample()
        await customUserAgentExample()
        await multipleHeadersExample()
        await acceptLanguageExample()
        await acceptEncodingExample()

        print("\n=== All examples completed ===")
    }
}

// MARK: - 5. Running the Examples

@main
struct CustomHeadersApp {
    static func main() async {
        let example = CustomHeadersExample()
        await example.runAllExamples()
    }
}
