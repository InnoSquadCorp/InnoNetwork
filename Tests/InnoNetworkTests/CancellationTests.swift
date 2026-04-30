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

        try await withThrowingTaskGroup(of: (CancellationTag, NetworkError?).self) { group in
            group.addTask { [client] in
                do {
                    _ = try await client.request(LongPollRequest(), tag: feed)
                    return (feed, nil)
                } catch let error as NetworkError {
                    return (feed, error)
                } catch {
                    return (feed, .underlying(SendableUnderlyingError(error), nil))
                }
            }
            group.addTask { [client] in
                do {
                    _ = try await client.request(LongPollRequest(), tag: feed)
                    return (feed, nil)
                } catch let error as NetworkError {
                    return (feed, error)
                } catch {
                    return (feed, .underlying(SendableUnderlyingError(error), nil))
                }
            }
            group.addTask { [client] in
                do {
                    _ = try await client.request(LongPollRequest(), tag: detail)
                    return (detail, nil)
                } catch let error as NetworkError {
                    return (detail, error)
                } catch {
                    return (detail, .underlying(SendableUnderlyingError(error), nil))
                }
            }

            // Wait until every request has actually entered the URL session.
            let waitDeadline = Date().addingTimeInterval(2.0)
            while session.startedRequestCount < 3, Date() < waitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(session.startedRequestCount == 3)

            await client.cancelAll(matching: feed)

            // Wait briefly so the detail task has a chance to terminate if the
            // cancellation incorrectly leaked across tags.
            try await Task.sleep(for: .milliseconds(100))

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

        try await withThrowingTaskGroup(of: (Bool, NetworkError?).self) { group in
            group.addTask { [client] in
                do {
                    _ = try await client.request(LongPollRequest(), tag: tagged)
                    return (true, nil)
                } catch let error as NetworkError {
                    return (true, error)
                } catch {
                    return (true, .underlying(SendableUnderlyingError(error), nil))
                }
            }
            group.addTask { [client] in
                do {
                    _ = try await client.request(LongPollRequest())
                    return (false, nil)
                } catch let error as NetworkError {
                    return (false, error)
                } catch {
                    return (false, .underlying(SendableUnderlyingError(error), nil))
                }
            }

            let waitDeadline = Date().addingTimeInterval(2.0)
            while session.startedRequestCount < 2, Date() < waitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(session.startedRequestCount == 2)

            await client.cancelAll(matching: tagged)
            try await Task.sleep(for: .milliseconds(100))

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
