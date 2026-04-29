import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

private struct StubProfile: Decodable, Sendable, Equatable {
    let id: Int
    let name: String
}


private struct StubbedProfileRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = StubProfile

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}


@Suite
struct StubBehaviorTests {
    private func makeFallbackClient() -> DefaultNetworkClient {
        DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://example.invalid"),
            session: MockURLSession()
        )
    }

    @Test
    func immediateBehaviorReturnsStubWithoutHittingNetwork() async throws {
        let stub = StubProfile(id: 7, name: "Stubbed User")
        let request = StubbedProfileRequest()
        let client = StubNetworkClient()
        client.register(stub, for: request, behavior: .immediate)

        let result = try await client.request(request)

        #expect(result == stub)
    }

    @Test
    func neverBehaviorBypassesStubAndUsesFallbackTransport() async {
        let stub = StubProfile(id: 7, name: "Stubbed User")
        let request = StubbedProfileRequest()
        let client = StubNetworkClient(fallback: makeFallbackClient())
        client.register(stub, for: request, behavior: .never)
        // The mock session has no canned response, so the transport path
        // will surface an error. The point of the assertion is that we did
        // *not* short-circuit to the stub: a thrown error proves the request
        // entered the live pipeline.

        await #expect(throws: (any Error).self) {
            _ = try await client.request(request)
        }
    }

    @Test
    func missingStubThrowsConfigurationError() async {
        let request = StubbedProfileRequest()
        let client = StubNetworkClient()

        await #expect(throws: (any Error).self) {
            _ = try await client.request(request)
        }
    }

    @Test
    func delayedBehaviorWaitsBeforeReturningStub() async throws {
        let stub = StubProfile(id: 99, name: "Delayed")
        let request = StubbedProfileRequest()
        let client = StubNetworkClient()
        client.register(stub, for: request, behavior: .delayed(seconds: 0.05))

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
        let request = StubbedProfileRequest()
        let client = StubNetworkClient()
        client.register(stub, for: request, behavior: .delayed(seconds: 60))

        let task = Task<StubProfile, Error> {
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
