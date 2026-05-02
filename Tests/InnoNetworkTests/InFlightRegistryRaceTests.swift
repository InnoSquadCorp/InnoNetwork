import Foundation
import Testing
import os

@testable import InnoNetwork

/// Stress tests for the cancel/register/deregister hand-off in
/// ``InFlightRegistry`` and ``DefaultNetworkClient.perform``. The registry
/// is purely synchronous (`OSAllocatedUnfairLock`-backed), so the tests
/// drive concurrent producers/consumers and assert the registry remains
/// internally consistent and that cancel handlers fire exactly once.
@Suite("InFlight Registry Race Tests")
struct InFlightRegistryRaceTests {

    // MARK: - Direct registry-level races

    @Test("Concurrent register/deregister keeps inFlightCount consistent")
    func concurrentRegisterDeregisterIsConsistent() async {
        let registry = InFlightRegistry()
        let producers = 50
        let perProducer = 20

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<producers {
                group.addTask {
                    for _ in 0..<perProducer {
                        let id = UUID()
                        registry.register(id: id, tag: nil, cancelHandler: {})
                        registry.deregister(id: id)
                    }
                }
            }
        }

        #expect(registry.inFlightCount == 0)
    }

    @Test("cancelAll fires every registered handler exactly once")
    func cancelAllFiresEachHandlerOnce() async {
        let registry = InFlightRegistry()
        let count = 200
        let counters = OSAllocatedUnfairLock<[UUID: Int]>(initialState: [:])

        for _ in 0..<count {
            let id = UUID()
            counters.withLock { $0[id] = 0 }
            registry.register(
                id: id, tag: nil,
                cancelHandler: { @Sendable in
                    counters.withLock { $0[id, default: 0] += 1 }
                })
        }

        registry.cancelAll()

        // Calling cancelAll a second time after the registry drained must
        // not refire any handler.
        registry.cancelAll()

        let snapshot = counters.withLock { $0 }
        #expect(snapshot.count == count)
        #expect(snapshot.values.allSatisfy { $0 == 1 })
        #expect(registry.inFlightCount == 0)
    }

    @Test("cancelAll(matching:) only drains entries with the matching tag")
    func cancelAllMatchingIsolatesByTag() async {
        let registry = InFlightRegistry()
        let firedA = OSAllocatedUnfairLock<Int>(initialState: 0)
        let firedB = OSAllocatedUnfairLock<Int>(initialState: 0)
        let firedNil = OSAllocatedUnfairLock<Int>(initialState: 0)
        let tagA: CancellationTag = "feature.a"
        let tagB: CancellationTag = "feature.b"

        for _ in 0..<10 {
            registry.register(
                id: UUID(), tag: tagA,
                cancelHandler: { @Sendable in
                    firedA.withLock { $0 += 1 }
                })
        }
        for _ in 0..<7 {
            registry.register(
                id: UUID(), tag: tagB,
                cancelHandler: { @Sendable in
                    firedB.withLock { $0 += 1 }
                })
        }
        for _ in 0..<5 {
            registry.register(
                id: UUID(), tag: nil,
                cancelHandler: { @Sendable in
                    firedNil.withLock { $0 += 1 }
                })
        }

        registry.cancelAll(matching: tagA)

        #expect(firedA.withLock { $0 } == 10)
        #expect(firedB.withLock { $0 } == 0)
        #expect(firedNil.withLock { $0 } == 0)
        #expect(registry.inFlightCount == 12)

        registry.cancelAll()
        #expect(firedB.withLock { $0 } == 7)
        #expect(firedNil.withLock { $0 } == 5)
        #expect(registry.inFlightCount == 0)
    }

    @Test("Concurrent cancelAll and register does not corrupt the registry")
    func concurrentCancelAllAndRegisterIsSafe() async {
        let registry = InFlightRegistry()
        let cancellations = OSAllocatedUnfairLock<Int>(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            // Producer: register a stream of entries.
            group.addTask {
                for _ in 0..<200 {
                    let id = UUID()
                    registry.register(
                        id: id, tag: nil,
                        cancelHandler: { @Sendable in
                            cancellations.withLock { $0 += 1 }
                        })
                    await Task.yield()
                }
            }
            // Consumer: drain via cancelAll repeatedly; concurrent registers
            // may either be drained immediately or remain for the next sweep.
            group.addTask {
                for _ in 0..<50 {
                    registry.cancelAll()
                    await Task.yield()
                }
            }
        }

        // Final sweep to drain any survivors.
        registry.cancelAll()
        #expect(registry.inFlightCount == 0)
        // Every registered handler must fire exactly once (drained once and
        // only once across all cancelAll invocations).
        #expect(cancellations.withLock { $0 } == 200)
    }

    // MARK: - DefaultNetworkClient.perform deregister guarantees

    private struct LongPollRequest: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EmptyResponse
        var method: HTTPMethod { .get }
        var path: String { "/poll" }
    }

    /// `URLSessionProtocol` stub that suspends each request indefinitely so
    /// the cancellation hand-off is observable on the registry.
    private final class HangingURLSession: URLSessionProtocol, Sendable {
        let started: OSAllocatedUnfairLock<Int> = .init(initialState: 0)
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            started.withLock { $0 += 1 }
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

    @Test("Outer-task cancellation drains DefaultNetworkClient inFlight state")
    func outerCancellationDrainsInFlight() async throws {
        let session = HangingURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )

        let task = Task<Void, Error> {
            _ = try await client.request(LongPollRequest())
        }

        // Wait until the request has actually entered the URL session so the
        // cancellation has registered work to interrupt.
        let waitDeadline = Date().addingTimeInterval(2.0)
        while session.started.withLock({ $0 }) == 0, Date() < waitDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        task.cancel()
        // The task body throws CancellationError → NetworkError.cancelled.
        await expectCancelled {
            _ = try await task.value
        }

        // The deregister path must run on cancellation; the registry
        // must end up empty so subsequent requests are not bookkept against
        // stale state.
        let drainDeadline = Date().addingTimeInterval(1.0)
        while client.inFlight.inFlightCount > 0, Date() < drainDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.inFlight.inFlightCount == 0)
    }

    @Test("cancelAll(matching:) drains tagged requests without leaking entries")
    func cancelAllMatchingDrainsTaggedRequests() async throws {
        let session = HangingURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )
        let tag: CancellationTag = "race.feature"

        let work = Task<Void, Error> {
            _ = try await client.request(LongPollRequest(), tag: tag)
        }

        let waitDeadline = Date().addingTimeInterval(2.0)
        while session.started.withLock({ $0 }) == 0, Date() < waitDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        await client.cancelAll(matching: tag)
        await expectCancelled {
            _ = try await work.value
        }

        let drainDeadline = Date().addingTimeInterval(1.0)
        while client.inFlight.inFlightCount > 0, Date() < drainDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.inFlight.inFlightCount == 0)
    }

    private func expectCancelled(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected NetworkError.cancelled")
        } catch NetworkError.cancelled {
            // Expected.
        } catch {
            Issue.record("Expected NetworkError.cancelled, got \(error)")
        }
    }
}
