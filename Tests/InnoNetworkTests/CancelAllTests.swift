import Foundation
import Testing
import os

@testable import InnoNetwork

/// `URLSessionProtocol` stub that suspends each request indefinitely until
/// it is cooperatively cancelled. Used to exercise
/// `DefaultNetworkClient.cancelAll()` because the real `MockURLSession`
/// returns a fixed response immediately, leaving no window for cancellation
/// to interrupt the work.
private final class HangingURLSession: URLSessionProtocol, Sendable {
    private let started: OSAllocatedUnfairLock<Int>

    init() {
        self.started = OSAllocatedUnfairLock(initialState: 0)
    }

    var startedRequestCount: Int {
        started.withLock { $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        started.withLock { $0 += 1 }
        // Sleep for a long time; cooperative cancellation will throw
        // CancellationError before the deadline.
        try await Task.sleep(for: .seconds(60))
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}


@Suite("Cancel All Tests")
struct CancelAllTests {

    private struct LongPollRequest: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EmptyResponse

        var method: HTTPMethod { .get }
        var path: String { "/poll" }
    }

    @Test("cancelAll interrupts every in-flight request")
    func cancelAllInterruptsActiveRequests() async throws {
        let hangingSession = HangingURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: hangingSession
        )

        let parallelism = 5

        try await withThrowingTaskGroup(of: NetworkError?.self) { group in
            for _ in 0..<parallelism {
                group.addTask {
                    do {
                        _ = try await client.request(LongPollRequest())
                        return nil
                    } catch let error as NetworkError {
                        return error
                    } catch {
                        return .underlying(SendableUnderlyingError(error), nil)
                    }
                }
            }

            // Wait until every request has actually entered the URL session
            // so the cancellation has work to interrupt.
            let waitDeadline = Date().addingTimeInterval(2.0)
            while hangingSession.startedRequestCount < parallelism, Date() < waitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(hangingSession.startedRequestCount == parallelism)

            await client.cancelAll()

            var cancelledCount = 0
            for try await result in group {
                if case .cancelled = result {
                    cancelledCount += 1
                }
            }
            #expect(cancelledCount == parallelism)
        }
    }

    @Test("cancelAll on idle client is a no-op")
    func cancelAllOnIdleClientIsNoop() async {
        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )
        await client.cancelAll()  // Should complete without crashing.
        await client.cancelAll()  // Idempotent.
    }

    @Test("Subsequent requests after cancelAll execute normally")
    func subsequentRequestsAfterCancelAllAreUnaffected() async throws {
        let session = MockURLSession()
        session.setMockResponse(statusCode: 204)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )

        await client.cancelAll()  // Drain (currently empty).
        // A new request after cancelAll must succeed — the registry must
        // not retain stale state.
        _ = try await client.request(EmptyEcho())
    }

    private struct EmptyEcho: APIDefinition, HTTPEmptyResponseDecodable {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EmptyEcho
        var method: HTTPMethod { .get }
        var path: String { "/echo" }

        static func emptyResponseValue() -> EmptyEcho { EmptyEcho() }
    }
}
