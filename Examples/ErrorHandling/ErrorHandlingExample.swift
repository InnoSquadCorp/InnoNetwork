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
struct ValidRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    var method: HTTPMethod { .get }
    var path: String { "/posts/1" }

}

// Request that will fail with 404
struct NotFoundRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    var method: HTTPMethod { .get }
    var path: String { "/posts/99999" }

}

// Invalid request configuration: endpoint paths must not include query strings.
struct InvalidRequestConfigurationRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    var method: HTTPMethod { .get }
    var path: String { "/posts/1?illegal=query" }

}

// Request with custom headers (for testing)
struct PostWithBody: APIDefinition {
    struct PostParameter: Encodable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    let parameters: PostParameter?

    var method: HTTPMethod { .post }
    var path: String { "/posts" }

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
        } catch let error as NetworkError {
            handleNetworkError(error)
        } catch {
            print("❌ Unknown error: \(error)")
        }
    }

    // Example 2: Handling request-configuration errors
    func invalidRequestConfigurationHandling() async {
        print("\n=== Example 2: Invalid Request Configuration Handling ===")
        do {
            let post = try await client.request(InvalidRequestConfigurationRequest())
            print("✅ Success: \(post.title)")
        } catch let error as NetworkError {
            handleNetworkError(error)
        } catch {
            print("❌ Unknown error: \(error)")
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
        } catch let error as NetworkError {
            handleNetworkError(error)
        } catch {
            print("❌ Unknown error: \(error)")
        }
    }

    // Example 4: Handling response data from errors
    func errorWithResponseData() async {
        print("\n=== Example 4: Error with Response Data ===")
        do {
            let post = try await client.request(NotFoundRequest())
            print("✅ Success: \(post.title)")
        } catch let error as NetworkError {
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
        } catch {
            print("❌ Unknown error: \(error)")
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
        } catch let error as NetworkError {
            handleNetworkError(error)
        } catch {
            print("❌ Unknown error: \(error)")
        }
    }

    // Example 6: Cancellation handling
    func cancellationHandling() async {
        print("\n=== Example 6: Cancellation Handling ===")

        let task = Task {
            do {
                let post = try await client.request(ValidRequest())
                print("✅ Success: \(post.title)")
            } catch let error as NetworkError {
                if case .cancelled = error {
                    print("⚠️  Request was cancelled")
                } else {
                    print("❌ Error: \(error)")
                }
            } catch is CancellationError {
                print("⚠️  Request was cancelled")
            } catch {
                print("❌ Error: \(error)")
            }
        }

        // Cancel the task after a short delay
        try? await Task.sleep(nanoseconds: 10_000_000)  // 0.01 seconds
        task.cancel()
        _ = await task.result
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

        case .trustEvaluationFailed(let reason):
            print("❌ Trust Evaluation Failed: \(reason)")

        case .cancelled:
            print("⚠️  Request Cancelled")

        case .timeout(let reason, let underlying):
            print("❌ Timeout: \(reason)")
            if let underlying {
                print("   Underlying Error: \(underlying)")
            }

        case .responseTooLarge(let limit, let observed):
            print("❌ Response Too Large")
            print("   Limit: \(limit) bytes")
            print("   Observed: \(observed) bytes")

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
