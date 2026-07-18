//
//  ErrorHandlingExample.swift
//  InnoNetwork Examples
//
//  This file demonstrates error handling patterns with InnoNetwork.
//  Shows how to catch and handle different types of network errors.
//

import Foundation
import InnoNetwork

// MARK: - 1. Client Configuration

private let clientConfiguration = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)

// MARK: - 2. Data Models

struct Post: Decodable {
    let id: Int
    let title: String
    let body: String
    let userId: Int
}

struct User: Decodable {
    let id: Int
    let name: String
    let email: String
}

// MARK: - 3. API Definitions

// Valid API request
@APIDefinition(method: .get, path: "/posts/1", auth: .anonymous)
struct ValidRequest {
    typealias APIResponse = Post
}

// Request that will fail with 404
@APIDefinition(method: .get, path: "/posts/99999", auth: .anonymous)
struct NotFoundRequest {
    typealias APIResponse = Post
}

// Deliberately uses the manual escape hatch: @APIDefinition would reject this
// invalid query-bearing path at compile time, while this scenario demonstrates
// the equivalent runtime guard for hand-written conformances.
struct InvalidRequestConfigurationRequest: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    var method: HTTPMethod { .get }
    var path: String { "/posts/1?illegal=query" }

}

// Request with custom headers (for testing)
@APIDefinition(method: .post, path: "/posts", auth: .anonymous)
struct PostWithBody {
    struct PostParameter: Encodable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    let parameters: PostParameter?

    init(title: String, body: String, userId: Int = 1) {
        self.parameters = PostParameter(title: title, body: body, userId: userId)
    }
}

// MARK: - 4. Error Handling Examples

actor ErrorHandlingExample {
    let client: DefaultNetworkClient

    init() {
        self.client = DefaultNetworkClient(configuration: clientConfiguration)
    }

    // Example 1: Basic error handling with do-catch
    func basicErrorHandling() async {
        print("=== Example 1: Basic Error Handling ===")
        do {
            let post = try await client.request(NotFoundRequest())
            print("✅ Success: \(post.title)")
        } catch {
            handleNetworkError(error)
        }
    }

    // Example 2: Handling request-configuration errors
    func invalidRequestConfigurationHandling() async {
        print("\n=== Example 2: Invalid Request Configuration Handling ===")
        do {
            let post = try await client.request(InvalidRequestConfigurationRequest())
            print("✅ Success: \(post.title)")
        } catch {
            handleNetworkError(error)
        }
    }

    // Example 3: Handling successful request
    func successfulRequest() async {
        print("\n=== Example 3: Successful Request ===")
        do {
            let post = try await client.request(ValidRequest())
            print("✅ Success!")
            print("Post ID: \(post.id)")
            print("Title: \(post.title)")
            print("Body: \(post.body)")
        } catch {
            handleNetworkError(error)
        }
    }

    // Example 4: Handling response data from errors
    func errorWithResponseData() async {
        print("\n=== Example 4: Error with Response Data ===")
        do {
            let post = try await client.request(NotFoundRequest())
            print("✅ Success: \(post.title)")
        } catch {
            // Access response data if available
            if let response = error.response {
                print("Status Code: \(response.statusCode)")
                print("Response Data Length: \(response.data.count)")

                // Try to decode error response if applicable
                if let jsonString = String(data: response.data, encoding: .utf8) {
                    print("Response Body: \(jsonString)")
                }
            }
            print("Error Description: \(error.localizedDescription)")
        }
    }

    // Example 5: Creating request with POST data
    func postRequest() async {
        print("\n=== Example 5: POST Request ===")
        do {
            let newPost = try await client.request(
                PostWithBody(
                    title: "Error Test Post",
                    body: "Testing error handling with POST",
                    userId: 1
                ))
            print("✅ Success! Created post #\(newPost.id)")
        } catch {
            handleNetworkError(error)
        }
    }

    // Example 6: Cancellation handling
    func cancellationHandling() async {
        print("\n=== Example 6: Cancellation Handling ===")

        let task = Task {
            do {
                let post = try await client.request(ValidRequest())
                print("✅ Success: \(post.title)")
            } catch NetworkError.cancelled {
                print("⚠️  Request was cancelled")
            } catch {
                print("❌ Error: \(error)")
            }
        }

        // Cancel the task after a short delay
        try? await Task.sleep(nanoseconds: 10_000_000)  // 0.01 seconds
        task.cancel()
        await task.value
    }

    // Helper method to handle different network errors
    func handleNetworkError(_ error: NetworkError) {
        switch error {
        case .configuration(let reason):
            print("❌ Configuration Error")
            switch reason {
            case .invalidBaseURL(let message):
                print("   Invalid Base URL: \(message)")
            case .invalidRequest(let message):
                print("   Invalid Request: \(message)")
            case .offline(let message):
                print("   Offline: \(message)")
            }

        case .statusCode(let response):
            print("❌ Status Code Error: \(response.statusCode)")
            if response.statusCode == 404 {
                print("   → Resource not found")
            } else if response.statusCode >= 500 {
                print("   → Server error")
            } else if response.statusCode >= 400 {
                print("   → Client error")
            }

        case .decoding(let stage, let decodingError, let response):
            print("❌ Decoding Error (\(stage)): \(decodingError)")
            print("   Status Code: \(response.statusCode)")

        case .underlying(let underlyingError, let response):
            print("❌ Underlying Error: \(underlyingError)")
            if let response = response {
                print("   Status Code: \(response.statusCode)")
            }

        case .reachability(let reason, let underlyingError, let response):
            print("❌ Reachability Error: \(reason)")
            print("   Underlying Error: \(underlyingError)")
            if let response = response {
                print("   Status Code: \(response.statusCode)")
            }

        case .trustEvaluationFailed(let reason):
            print("❌ Trust Evaluation Failed: \(reason)")

        case .cancelled:
            print("⚠️  Request Cancelled")

        case .timeout(let reason, let underlying):
            print("❌ Timeout: \(reason)")
            if let underlying {
                print("   Underlying Error: \(underlying)")
            }

        @unknown default:
            print("❌ Unhandled NetworkError: \(error)")
        }
    }

    // Run all examples
    func runAllExamples() async {
        await successfulRequest()
        await basicErrorHandling()
        await invalidRequestConfigurationHandling()
        await errorWithResponseData()
        await postRequest()
        await cancellationHandling()

        print("\n=== All examples completed ===")
    }
}

// MARK: - 5. Running the Examples

@main
struct ErrorHandlingApp {
    static func main() async {
        let example = ErrorHandlingExample()
        await example.runAllExamples()
    }
}
