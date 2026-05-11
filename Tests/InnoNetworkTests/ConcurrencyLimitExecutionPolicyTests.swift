import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct ConcurrencyLimitExecutionPolicyTests {
    @Test
    func policyForwardsRequestThroughChain() async throws {
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 2)
        let policy = ConcurrencyLimitExecutionPolicy(bucket: bucket)

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
            next: RequestExecutionNext { request in
                Response(
                    statusCode: 200,
                    data: Data(),
                    request: request,
                    response: HTTPURLResponse(
                        url: request.url ?? url,
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
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
        let policy = ConcurrencyLimitExecutionPolicy(bucket: bucket)

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
            next: RequestExecutionNext { request in
                let mid = await bucket.available
                await observedAvailable.set(mid)
                return Response(
                    statusCode: 200,
                    data: Data(),
                    request: request,
                    response: HTTPURLResponse(
                        url: request.url ?? url,
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
        let bucket = ConcurrencyTokenBucket(maxConcurrent: 1)
        let policy = ConcurrencyLimitExecutionPolicy(bucket: bucket)
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
                next: RequestExecutionNext { _ in
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
