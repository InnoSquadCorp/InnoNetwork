import Foundation
import Testing
import os

@testable import InnoNetwork

/// `URLSessionProtocol` stub that suspends every request indefinitely until
/// cooperative cancellation interrupts it. Mirrors the helper in
/// `CancelAllTests` but is local so the two suites can evolve independently.
private final class HangingSession: URLSessionProtocol, Sendable {
    private let started: OSAllocatedUnfairLock<Int>

    init() {
        self.started = OSAllocatedUnfairLock(initialState: 0)
    }

    var startedRequestCount: Int {
        started.withLock { $0 }
    }

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


private actor CompletionRecorder<Key: Hashable & Sendable> {
    private var counts: [Key: Int] = [:]

    func record(_ key: Key) {
        counts[key, default: 0] += 1
    }

    func count(for key: Key) -> Int {
        counts[key, default: 0]
    }
}


private func waitUntil(
    timeout: TimeInterval = 2.0,
    pollInterval: Duration = .milliseconds(20),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }
    #expect(await condition())
}


@Suite("Tag-based Cancellation Tests")
struct CancellationTests {

    private struct LongPollRequest: APIDefinition {
        typealias Parameter = EmptyParameter
        typealias APIResponse = EmptyResponse

        var method: HTTPMethod { .get }
        var path: String { "/poll" }
    }

    @Test("cancelAll(matching:) only cancels requests with the matching tag")
    func cancelAllByTagAffectsOnlyMatchingTag() async throws {
        let session = HangingSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )

        let feed: CancellationTag = "feed"
        let detail: CancellationTag = "detail"
        let completions = CompletionRecorder<CancellationTag>()

        try await withThrowingTaskGroup(of: (CancellationTag, NetworkError?).self) { group in
            group.addTask { [client, completions] in
                let result: (CancellationTag, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(), tag: feed)
                    result = (feed, nil)
                } catch let error as NetworkError {
                    result = (feed, error)
                } catch {
                    result = (feed, .underlying(SendableUnderlyingError(error), nil))
                }
                await completions.record(feed)
                return result
            }
            group.addTask { [client, completions] in
                let result: (CancellationTag, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(), tag: feed)
                    result = (feed, nil)
                } catch let error as NetworkError {
                    result = (feed, error)
                } catch {
                    result = (feed, .underlying(SendableUnderlyingError(error), nil))
                }
                await completions.record(feed)
                return result
            }
            group.addTask { [client, completions] in
                let result: (CancellationTag, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(), tag: detail)
                    result = (detail, nil)
                } catch let error as NetworkError {
                    result = (detail, error)
                } catch {
                    result = (detail, .underlying(SendableUnderlyingError(error), nil))
                }
                await completions.record(detail)
                return result
            }

            // Wait until every request has actually entered the URL session.
            let waitDeadline = Date().addingTimeInterval(2.0)
            while session.startedRequestCount < 3, Date() < waitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(session.startedRequestCount == 3)

            await client.cancelAll(matching: feed)
            try await waitUntil {
                await completions.count(for: feed) == 2
            }

            // Wait briefly so the detail task has a chance to terminate if the
            // cancellation incorrectly leaked across tags.
            try await Task.sleep(for: .milliseconds(100))
            #expect(await completions.count(for: detail) == 0)

            // Tear down the surviving request so the suite finishes.
            await client.cancelAll()

            var feedCancelled = 0
            var detailCancelled = 0
            for try await (tag, error) in group {
                guard case .cancelled = error else { continue }
                if tag == feed { feedCancelled += 1 }
                if tag == detail { detailCancelled += 1 }
            }
            #expect(feedCancelled == 2)
            #expect(detailCancelled == 1)
        }
    }

    @Test("cancelAll(matching:) does not affect untagged requests until the global cancel runs")
    func cancelByTagLeavesUntaggedRequestsAlone() async throws {
        let session = HangingSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )

        let tagged: CancellationTag = "tagged"
        let completions = CompletionRecorder<Bool>()

        try await withThrowingTaskGroup(of: (Bool, NetworkError?).self) { group in
            group.addTask { [client, completions] in
                let result: (Bool, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(), tag: tagged)
                    result = (true, nil)
                } catch let error as NetworkError {
                    result = (true, error)
                } catch {
                    result = (true, .underlying(SendableUnderlyingError(error), nil))
                }
                await completions.record(true)
                return result
            }
            group.addTask { [client, completions] in
                let result: (Bool, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest())
                    result = (false, nil)
                } catch let error as NetworkError {
                    result = (false, error)
                } catch {
                    result = (false, .underlying(SendableUnderlyingError(error), nil))
                }
                await completions.record(false)
                return result
            }

            let waitDeadline = Date().addingTimeInterval(2.0)
            while session.startedRequestCount < 2, Date() < waitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(session.startedRequestCount == 2)

            await client.cancelAll(matching: tagged)
            try await waitUntil {
                await completions.count(for: true) == 1
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await completions.count(for: false) == 0)

            // Untagged request still in flight — cancel everything to let the
            // task group drain.
            await client.cancelAll()

            var taggedCancelled = false
            var untaggedCancelled = false
            for try await (isTagged, error) in group {
                guard case .cancelled = error else { continue }
                if isTagged {
                    taggedCancelled = true
                } else {
                    untaggedCancelled = true
                }
            }
            #expect(taggedCancelled)
            #expect(untaggedCancelled)
        }
    }

    @Test("request(_:tag:) with nil tag behaves identically to request(_:)")
    func requestWithNilTagBehavesAsUntagged() async throws {
        let session = HangingSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )

        try await withThrowingTaskGroup(of: NetworkError?.self) { group in
            group.addTask {
                do {
                    _ = try await client.request(LongPollRequest(), tag: nil)
                    return nil
                } catch let error as NetworkError {
                    return error
                } catch {
                    return .underlying(SendableUnderlyingError(error), nil)
                }
            }

            let waitDeadline = Date().addingTimeInterval(2.0)
            while session.startedRequestCount < 1, Date() < waitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(session.startedRequestCount == 1)

            // cancelAll(matching:) with an unrelated tag must not interrupt
            // an untagged request.
            await client.cancelAll(matching: "unrelated")
            try await Task.sleep(for: .milliseconds(100))

            await client.cancelAll()

            for try await error in group {
                if case .cancelled = error {
                    // expected
                } else {
                    Issue.record("Expected .cancelled, got \(String(describing: error))")
                }
            }
        }
    }

    @Test("CancellationTag string literal initialization")
    func cancellationTagStringLiteralInit() {
        let tag: CancellationTag = "screen.feed"
        #expect(tag.rawValue == "screen.feed")
        #expect(tag == CancellationTag("screen.feed"))
    }
}
