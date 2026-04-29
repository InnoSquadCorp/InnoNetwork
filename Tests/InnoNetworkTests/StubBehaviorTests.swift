import Foundation
import Testing
import os

@testable import InnoNetwork

private struct StubProfile: Decodable, Sendable, Equatable {
    let id: Int
    let name: String
}


private struct StubbedProfileRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = StubProfile

    let stub: StubProfile?
    let behavior: StubBehavior

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }

    var sampleResponse: StubProfile? { stub }
    var sampleBehavior: StubBehavior { behavior }
}


private final class SampleResponseProbe: Sendable {
    private let accessCount = OSAllocatedUnfairLock<Int>(initialState: 0)

    func recordAccess() {
        accessCount.withLock { $0 += 1 }
    }

    var count: Int {
        accessCount.withLock { $0 }
    }
}


private struct ProbedStubbedProfileRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = StubProfile

    let behavior: StubBehavior
    let probe: SampleResponseProbe

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }

    var sampleResponse: StubProfile? {
        probe.recordAccess()
        return StubProfile(id: 42, name: "Computed Stub")
    }

    var sampleBehavior: StubBehavior { behavior }
}


@Suite
struct StubBehaviorTests {
    private func makeClient() -> DefaultNetworkClient {
        DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://example.invalid"),
            session: MockURLSession()
        )
    }

    @Test
    func immediateBehaviorReturnsStubWithoutHittingNetwork() async throws {
        let stub = StubProfile(id: 7, name: "Stubbed User")
        let request = StubbedProfileRequest(stub: stub, behavior: .immediate)
        let client = makeClient()

        let result = try await client.request(request)

        #expect(result == stub)
    }

    @Test
    func neverBehaviorBypassesStubAndUsesTransport() async {
        let stub = StubProfile(id: 7, name: "Stubbed User")
        let request = StubbedProfileRequest(stub: stub, behavior: .never)
        // The mock session has no canned response, so the transport path
        // will surface an error. The point of the assertion is that we did
        // *not* short-circuit to the stub: a thrown error proves the request
        // entered the live pipeline.
        let client = makeClient()

        await #expect(throws: (any Error).self) {
            _ = try await client.request(request)
        }
    }

    @Test
    func neverBehaviorDoesNotEvaluateSampleResponse() async {
        let probe = SampleResponseProbe()
        let request = ProbedStubbedProfileRequest(behavior: .never, probe: probe)
        let client = makeClient()

        await #expect(throws: (any Error).self) {
            _ = try await client.request(request)
        }
        #expect(probe.count == 0)
    }

    @Test
    func nilSampleResponseBypassesStubEvenWhenBehaviorIsImmediate() async {
        let request = StubbedProfileRequest(stub: nil, behavior: .immediate)
        let client = makeClient()

        await #expect(throws: (any Error).self) {
            _ = try await client.request(request)
        }
    }

    @Test
    func delayedBehaviorWaitsBeforeReturningStub() async throws {
        let stub = StubProfile(id: 99, name: "Delayed")
        let request = StubbedProfileRequest(stub: stub, behavior: .delayed(seconds: 0.05))
        let client = makeClient()

        let started = ContinuousClock.now
        let result = try await client.request(request)
        let elapsed = ContinuousClock.now - started

        #expect(result == stub)
        // Allow generous slack so CI scheduler noise does not flake the test;
        // we only care that the stub did not short-circuit instantaneously.
        #expect(elapsed >= .milliseconds(40))
    }

    @Test
    func delayedBehaviorMapsCancellationToNetworkCancelled() async throws {
        let stub = StubProfile(id: 100, name: "Slow")
        let request = StubbedProfileRequest(stub: stub, behavior: .delayed(seconds: 60))
        let client = makeClient()

        let task = Task {
            try await client.request(request)
        }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected delayed stub cancellation to throw")
        } catch let error as NetworkError {
            switch error {
            case .cancelled:
                break
            default:
                Issue.record("Expected NetworkError.cancelled, got \(error)")
            }
        } catch {
            Issue.record("Expected NetworkError.cancelled, got \(error)")
        }
    }
}
