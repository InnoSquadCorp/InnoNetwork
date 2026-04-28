import Foundation
import Testing

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
}
