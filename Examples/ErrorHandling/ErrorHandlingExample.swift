//
//  ErrorHandlingExample.swift
//  InnoNetwork Examples
//
//  This file demonstrates error handling patterns with InnoNetwork.
//  `NetworkError` is the only error type the library throws. The examples
//  show how to match its cases, how to decide on recovery from its coarse
//  classification, and how to keep a payload-free summary for logs and UI.
//

import Foundation
import InnoNetwork

// MARK: - 1. Client Configuration

private let baseURL = URL(string: "https://jsonplaceholder.typicode.com")!

private let clientConfiguration = NetworkConfiguration.safeDefaults(baseURL: baseURL)

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

    // Example 7: Deciding on recovery without matching every case
    func categoryDrivenHandling() async {
        print("\n=== Example 7: Category-Driven Handling ===")
        do {
            let post = try await client.request(NotFoundRequest())
            print("✅ Success: \(post.title)")
        } catch {
            // `category` is the coarse bucket, `isRetriableHint` says whether
            // the failure class is usually transient, and `isUserVisible`
            // says whether it is worth showing to the user at all.
            print("Category: \(error.category)")
            print("Usually transient: \(error.isRetriableHint)")
            print("Worth showing to the user: \(error.isUserVisible)")
            print("Suggested action: \(suggestedAction(for: error))")
        }
    }

    // Example 8: A locally configured policy rejects the exchange
    func policyRejectionHandling() async {
        print("\n=== Example 8: Policy Rejection ===")
        // A 64-byte response limit is far below the size of one post, so the
        // library stops reading the body and reports a policy rejection.
        let boundedClient = DefaultNetworkClient(
            configuration: .advanced(
                baseURL: baseURL,
                resilience: ResiliencePack(bodyBuffering: .streaming(maxBytes: 64))
            )
        )
        do {
            let post = try await boundedClient.request(ValidRequest())
            print("✅ Success: \(post.title)")
        } catch NetworkError.policyRejected(.responseBodyLimitExceeded(let limitBytes, let observedBytes)) {
            // The rejection is a local decision. It says nothing about the
            // server's health, so the built-in retry policy never retries it
            // and the circuit breaker never counts it.
            print("❌ Response too large: observed \(observedBytes) bytes, limit \(limitBytes) bytes")
            print("   → Raise the limit or request less data; a retry gives the same result")
        } catch {
            handleNetworkError(error)
        }
        await boundedClient.shutdown()
    }

    // Example 9: Authentication failures are their own case
    func authenticationFailureHandling(_ error: NetworkError) {
        guard case .authentication(let failure) = error else {
            return
        }
        switch failure {
        case .refreshFailed(let cause):
            // The session refresh operation failed. Replaying the request
            // cannot repair the session, so ask the user to sign in again.
            print("❌ Session refresh failed: \(cause.message)")
            print("   → Sign the user out and ask them to sign in again")
        case .credential(let reason):
            // A named request credential could not be selected, acquired or
            // applied. `reason` is a secret-free `RequestSecurityFailure`.
            print("❌ Request credential failed: \(reason)")
        }
    }

    // Example 10: A payload-free summary for logs, analytics and view state
    func errorSummary() async {
        print("\n=== Example 10: Error Summary ===")
        // `start(_:)` returns a handle before the request completes.
        // `value()` throws the same NetworkError that `request(_:)` throws.
        let operation = client.start(NotFoundRequest())
        do {
            let post = try await operation.value()
            print("✅ Success: \(post.title)")
        } catch {
            // `error.summary` carries no body, headers, URL or underlying
            // error text. It has no request context either, so it never
            // recommends a replay.
            let plain = error.summary
            // The operation knows the request's method, authentication and
            // replay safety, so its summary can recommend a recovery.
            let contextual = await operation.failureSummary() ?? plain
            print("Category: \(contextual.category)")
            print("Stable code: \(contextual.code)")
            if let statusCode = contextual.statusCode {
                print("HTTP status: \(statusCode)")
            }
            print("Generic message: \(contextual)")
            print("Recovery without context: \(plain.recovery)")
            print("Recovery for this request: \(describe(contextual.recovery))")
        }
    }

    // Example 11: The classification of failures that need no network
    func classificationTable() {
        print("\n=== Example 11: Classification Table ===")
        let samples: [(label: String, error: NetworkError)] = [
            ("Request timeout", .timeout(reason: .requestTimeout)),
            (
                "Body over the limit",
                .policyRejected(.responseBodyLimitExceeded(limitBytes: 1_024, observedBytes: 4_096))
            ),
            ("Rate-limit queue full", .policyRejected(.rateLimitQueueFull)),
            ("Expired credential", .authentication(.credential(.credentialExpired))),
            ("Offline preflight", .configuration(reason: .offline("No network path"))),
            ("Cancelled", .cancelled),
        ]
        for sample in samples {
            // A GET that uses session authentication is the request context.
            let summary = sample.error.summary(method: .get, authentication: .required)
            print(
                "\(sample.label): category=\(summary.category), code=\(summary.code), "
                    + "transient=\(sample.error.isRetriableHint), recovery=\(summary.recovery)"
            )
            authenticationFailureHandling(sample.error)
        }
    }

    // Maps the coarse category to one user-facing decision. A new case in a
    // category needs no change here.
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

    func describe(_ recovery: NetworkRecoveryDisposition) -> String {
        switch recovery {
        case .retry:
            return "retry (within your own attempt budget)"
        case .waitForConnectivity:
            return "wait for connectivity"
        case .reauthenticate:
            return "sign in again"
        case .doNotRetry:
            return "do not retry"
        case .none:
            return "nothing to do"
        }
    }

    func describe(_ rejection: NetworkPolicyRejection) -> String {
        switch rejection {
        case .responseBodyLimitExceeded(let limitBytes, let observedBytes):
            return "response body of \(observedBytes) bytes exceeds the \(limitBytes)-byte limit"
        case .circuitOpen(let open):
            return "circuit breaker is open for \(open.host); retry after \(open.retryAfter) seconds"
        case .rateLimitQueueFull:
            return "rate-limit queue is full"
        case .rateLimitScopeLimitReached:
            return "rate-limit scope registry is full"
        case .admissionQueueFull:
            return "request admission queue is full"
        case .admissionWaitExpired:
            return "request waited in the admission queue past its deadline"
        case .nonHTTPResponse:
            return "the transport delivered a response that is not HTTP"
        }
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
            case .invalidPayload:
                print("   Invalid Payload: request encoding or validation failed")
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
            // Only transport errors the built-in mapper did not classify
            // arrive here. Failures the library decides locally use
            // `.policyRejected` or `.authentication`.
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

        case .policyRejected(let rejection):
            print("❌ Policy Rejection: \(describe(rejection))")
            print("   → Not retried: the same request gives the same result")

        case .authentication:
            authenticationFailureHandling(error)

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
        await categoryDrivenHandling()
        await policyRejectionHandling()
        await errorSummary()
        classificationTable()

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
