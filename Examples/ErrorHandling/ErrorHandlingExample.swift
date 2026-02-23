//
//  ErrorHandlingExample.swift
//  InnoNetwork Examples
//
//  This file demonstrates error handling patterns with InnoNetwork.
//  Shows how to catch and handle different types of network errors.
//

import Foundation
import InnoNetwork

// MARK: - 1. API Configuration

struct MyAPI: APIConfigure {
    var host: String { "https://jsonplaceholder.typicode.com" }
    var basePath: String { "" }
}

API.configure(MyAPI())

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
actor ValidRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    var method: HTTPMethod { .get }
    var path: String { "/posts/1" }

    var configuration: NetworkConfiguration? {
        NetworkConfiguration(baseURL: URL(string: "https://jsonplaceholder.typicode.com")!)
    }
}

// Request that will fail with 404
actor NotFoundRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    var method: HTTPMethod { .get }
    var path: String { "/posts/99999" }

    var configuration: NetworkConfiguration? {
        NetworkConfiguration(baseURL: URL(string: "https://jsonplaceholder.typicode.com")!)
    }
}

// Invalid URL request
actor InvalidURLRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    var method: HTTPMethod { .get }
    var path: String { "/posts/1" }

    var configuration: NetworkConfiguration? {
        NetworkConfiguration(baseURL: URL(string: "https://invalid-domain-12345.com")!)
    }
}

// Request with custom headers (for testing)
actor PostWithBody: APIDefinition {
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

    var configuration: NetworkConfiguration? {
        NetworkConfiguration(baseURL: URL(string: "https://jsonplaceholder.typicode.com")!)
    }

    init(title: String, body: String, userId: Int = 1) {
        self.parameters = PostParameter(title: title, body: body, userId: userId)
    }
}

// MARK: - 4. Error Handling Examples

actor ErrorHandlingExample {
    let client: DefaultNetworkClient

    init() throws {
        self.client = try DefaultNetworkClient(configuration: MyAPI())
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

    // Example 2: Handling invalid URL error
    func invalidURLHandling() async {
        print("\n=== Example 2: Invalid URL Handling ===")
        do {
            let post = try await client.request(InvalidURLRequest())
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
        }
    }

    // Example 5: Creating request with POST data
    func postRequest() async {
        print("\n=== Example 5: POST Request ===")
        do {
            let newPost = try await client.request(PostWithBody(
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
            } catch let error as NetworkError where error == .cancelled {
                print("⚠️  Request was cancelled")
            } catch {
                print("❌ Error: \(error)")
            }
        }

        // Cancel the task after a short delay
        try? await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        task.cancel()
    }

    // Helper method to handle different network errors
    func handleNetworkError(_ error: NetworkError) {
        switch error {
        case .invalidBaseURL(let urlString):
            print("❌ Invalid Base URL: \(urlString)")

        case .jsonMapping(let response):
            print("❌ JSON Mapping Error")
            print("   Status Code: \(response.statusCode)")
            print("   Data: \(String(data: response.data, encoding: .utf8) ?? "N/A")")

        case .statusCode(let response):
            print("❌ Status Code Error: \(response.statusCode)")
            if response.statusCode == 404 {
                print("   → Resource not found")
            } else if response.statusCode >= 500 {
                print("   → Server error")
            } else if response.statusCode >= 400 {
                print("   → Client error")
            }

        case .objectMapping(let decodingError, let response):
            print("❌ Object Mapping Error: \(decodingError)")
            print("   Status Code: \(response.statusCode)")

        case .nonHTTPResponse(let response):
            print("❌ Non-HTTP Response: \(response)")

        case .underlying(let underlyingError, let response):
            print("❌ Underlying Error: \(underlyingError)")
            if let response = response {
                print("   Status Code: \(response.statusCode)")
            }

        case .undefined:
            print("❌ Undefined Error")

        case .cancelled:
            print("⚠️  Request Cancelled")
        }
    }

    // Run all examples
    func runAllExamples() async {
        await successfulRequest()
        await basicErrorHandling()
        await invalidURLHandling()
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
        do {
            let example = try ErrorHandlingExample()
            await example.runAllExamples()
        } catch {
            print("Failed to create network client: \(error)")
        }
    }
}
