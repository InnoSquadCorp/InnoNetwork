import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct ConcurrencyLimitExecutionPolicyTests {
    @Test
    func publicInitializerClampsCapacityToOne() {
        let policy = ConcurrencyLimitExecutionPolicy(maxConcurrent: 0)

        #expect(policy.maxConcurrent == 1)
    }

    @Test
    func copiedPolicyValuesShareOneAdmissionQueue() {
        let policy = ConcurrencyLimitExecutionPolicy(maxConcurrent: 2)
        let copy = policy

        #expect(policy.bucket === copy.bucket)
    }

    @Test
    func policyForwardsRequestThroughChain() async throws {
        let policy = ConcurrencyLimitExecutionPolicy(maxConcurrent: 2)

        let url = URL(string: "https://api.example.com/x")!
        let response = try await policy.execute(
            input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
            context: RequestExecutionContext(
                requestID: UUID(),
                retryIndex: 0,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: []
            ),
            next: RequestExecutionNext {
                Response(
                    statusCode: 200,
                    data: Data(),
                    request: URLRequest(url: url),
                    response: HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        #expect(response.statusCode == 200)
    }

    @Test
    func policyAcquiresAndReleasesAroundChain() async throws {
        let policy = ConcurrencyLimitExecutionPolicy(maxConcurrent: 1)
        let bucket = policy.bucket

        let url = URL(string: "https://api.example.com/x")!
        let observedAvailable = ObservedAvailable()

        _ = try await policy.execute(
            input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
            context: RequestExecutionContext(
                requestID: UUID(),
                retryIndex: 0,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: []
            ),
            next: RequestExecutionNext {
                let mid = await bucket.available
                await observedAvailable.set(mid)
                return Response(
                    statusCode: 200,
                    data: Data(),
                    request: URLRequest(url: url),
                    response: HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let mid = await observedAvailable.value
        let after = await bucket.available
        #expect(mid == 0)
        #expect(after == 1)
    }

    @Test
    func policyReleasesBeforeRethrowingChainFailure() async throws {
        let policy = ConcurrencyLimitExecutionPolicy(maxConcurrent: 1)
        let bucket = policy.bucket
        let url = URL(string: "https://api.example.com/x")!

        do {
            _ = try await policy.execute(
                input: RequestExecutionInput(request: URLRequest(url: url), requestID: UUID(), retryIndex: 0),
                context: RequestExecutionContext(
                    requestID: UUID(),
                    retryIndex: 0,
                    metricsReporter: nil,
                    trustPolicy: .systemDefault,
                    eventObservers: []
                ),
                next: RequestExecutionNext {
                    throw PolicyProbeError.failure
                }
            )
            Issue.record("Expected policy to rethrow chain failure")
        } catch PolicyProbeError.failure {
        }

        #expect(await bucket.available == 1)
    }
}

private actor ObservedAvailable {
    private(set) var value: Int = -1
    func set(_ v: Int) {
        value = v
    }
}

private enum PolicyProbeError: Error {
    case failure
}
