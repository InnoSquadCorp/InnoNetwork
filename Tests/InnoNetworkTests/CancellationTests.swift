import Foundation
import Testing
import os

@testable import InnoNetwork

/// `URLSessionProtocol` stub that holds each request behind a continuation.
/// Tests can wait for exact start/cancellation signals and explicitly complete
/// surviving paths without relying on polling or wall-clock delays.
private final class HangingSession: URLSessionProtocol, Sendable {
    private struct PendingRequest {
        let url: URL
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
    }

    private struct CountWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var startedRequestCount = 0
        var startedPathCounts: [String: Int] = [:]
        var cancelledPathCounts: [String: Int] = [:]
        var pendingRequests: [UUID: PendingRequest] = [:]
        var cancelledBeforeRegistration: Set<UUID> = []
        var startedCountWaiters: [CountWaiter] = []
        var startedPathWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        var cancelledPathWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var startedRequestCount: Int {
        state.withLock { $0.startedRequestCount }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }

        let id = UUID()
        let path = url.path
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let registration = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    guard state.cancelledBeforeRegistration.remove(id) == nil else {
                        return (false, [])
                    }

                    state.pendingRequests[id] = PendingRequest(url: url, continuation: continuation)
                    state.startedRequestCount += 1
                    state.startedPathCounts[path, default: 0] += 1

                    var readyWaiters: [CheckedContinuation<Void, Never>] = []
                    state.startedCountWaiters.removeAll { waiter in
                        guard state.startedRequestCount >= waiter.minimumCount else { return false }
                        readyWaiters.append(waiter.continuation)
                        return true
                    }
                    readyWaiters.append(contentsOf: state.startedPathWaiters.removeValue(forKey: path) ?? [])
                    return (true, readyWaiters)
                }

                guard registration.0 else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                registration.1.forEach { $0.resume() }
            }
        } onCancel: {
            cancelRequest(id: id, path: path)
        }
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.startedRequestCount < count else { return true }
                state.startedCountWaiters.append(
                    CountWaiter(minimumCount: count, continuation: continuation)
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func waitUntilStarted(path: String) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.startedPathCounts[path, default: 0] == 0 else { return true }
                state.startedPathWaiters[path, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func waitUntilCancelled(path: String) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.cancelledPathCounts[path, default: 0] == 0 else { return true }
                state.cancelledPathWaiters[path, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func succeed(path: String) {
        let pending = state.withLock { state -> [PendingRequest] in
            let ids = state.pendingRequests.compactMap { id, request in
                request.url.path == path ? id : nil
            }
            return ids.compactMap { state.pendingRequests.removeValue(forKey: $0) }
        }

        #expect(pending.count == 1, "Expected exactly one pending request for \(path)")
        for request in pending {
            guard
                let response = HTTPURLResponse(
                    url: request.url,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )
            else {
                request.continuation.resume(throwing: URLError(.badServerResponse))
                continue
            }
            request.continuation.resume(returning: (Data(), response))
        }
    }

    private func cancelRequest(id: UUID, path: String) {
        let cancellation = state.withLock { state -> (PendingRequest?, [CheckedContinuation<Void, Never>]) in
            state.cancelledPathCounts[path, default: 0] += 1
            let waiters = state.cancelledPathWaiters.removeValue(forKey: path) ?? []
            guard let pending = state.pendingRequests.removeValue(forKey: id) else {
                state.cancelledBeforeRegistration.insert(id)
                return (nil, waiters)
            }
            return (pending, waiters)
        }

        cancellation.0?.continuation.resume(throwing: CancellationError())
        cancellation.1.forEach { $0.resume() }
    }
}


private actor BlockingResponseCache: ResponseCache {
    private let cached: CachedResponse
    private var getStarted = false
    private var getWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(cached: CachedResponse) {
        self.cached = cached
    }

    func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        _ = key
        getStarted = true
        getWaiter?.resume()
        getWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
        return cached
    }

    func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        _ = (key, value)
    }

    func invalidate(_ key: ResponseCacheKey) async {
        _ = key
    }

    func invalidateTargetURI(_ targetURI: String) async {
        _ = targetURI
    }

    func waitForGet() async {
        guard getStarted == false else { return }
        await withCheckedContinuation { continuation in
            getWaiter = continuation
        }
    }

    func releaseGet() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}


@Suite("Tag-based Cancellation Tests")
struct CancellationTests {

    private struct LongPollRequest: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = EmptyResponse

        var method: HTTPMethod { .get }
        let path: String
    }

    private struct CachedPayload: Codable, Sendable, Equatable {
        let ok: Bool
    }

    private struct CachedPayloadRequest: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = CachedPayload

        var method: HTTPMethod { .get }
        var path: String { "/cached" }
    }

    @Test("request cancellation is checked before returning cache hits")
    func cancellationBeforeCacheHitReturnThrows() async throws {
        let payload = try JSONEncoder().encode(CachedPayload(ok: true))
        let cache = BlockingResponseCache(cached: CachedResponse(data: payload))
        let session = HangingSession()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let task = Task {
            try await client.request(CachedPayloadRequest())
        }

        await cache.waitForGet()
        task.cancel()
        await cache.releaseGet()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation before cache-hit return to throw")
        } catch let error as NetworkError {
            guard case .cancelled = error else {
                Issue.record("Expected NetworkError.cancelled, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected NetworkError.cancelled, got \(error)")
        }
        #expect(session.startedRequestCount == 0)
    }

    @Test("cancelAll(matching:) only cancels requests with the matching tag")
    func cancelAllByTagAffectsOnlyMatchingTag() async throws {
        let session = HangingSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: session
        )

        let feed: CancellationTag = "feed"
        let detail: CancellationTag = "detail"
        let firstFeedPath = "/feed/first"
        let secondFeedPath = "/feed/second"
        let detailPath = "/detail"

        try await withThrowingTaskGroup(of: (CancellationTag, NetworkError?).self) { group in
            group.addTask { [client] in
                let result: (CancellationTag, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(path: firstFeedPath), tag: feed)
                    result = (feed, nil)
                } catch let error as NetworkError {
                    result = (feed, error)
                } catch {
                    result = (feed, .underlying(SendableUnderlyingError(error), nil))
                }
                return result
            }
            group.addTask { [client] in
                let result: (CancellationTag, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(path: secondFeedPath), tag: feed)
                    result = (feed, nil)
                } catch let error as NetworkError {
                    result = (feed, error)
                } catch {
                    result = (feed, .underlying(SendableUnderlyingError(error), nil))
                }
                return result
            }
            group.addTask { [client] in
                let result: (CancellationTag, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(path: detailPath), tag: detail)
                    result = (detail, nil)
                } catch let error as NetworkError {
                    result = (detail, error)
                } catch {
                    result = (detail, .underlying(SendableUnderlyingError(error), nil))
                }
                return result
            }

            await session.waitUntilStarted(count: 3)

            await client.cancelAll(matching: feed)
            await session.waitUntilCancelled(path: firstFeedPath)
            await session.waitUntilCancelled(path: secondFeedPath)
            session.succeed(path: detailPath)

            var feedCancelled = 0
            var detailSucceeded = false
            for try await (tag, error) in group {
                if tag == feed {
                    guard case .cancelled = error else {
                        Issue.record("Expected feed request cancellation, got \(String(describing: error))")
                        continue
                    }
                    feedCancelled += 1
                } else if tag == detail {
                    if error == nil {
                        detailSucceeded = true
                    } else {
                        Issue.record("Expected detail request success, got \(String(describing: error))")
                    }
                }
            }
            #expect(feedCancelled == 2)
            #expect(detailSucceeded)
        }
    }

    @Test("cancelAll(matching:) does not affect untagged requests until the global cancel runs")
    func cancelByTagLeavesUntaggedRequestsAlone() async throws {
        let session = HangingSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: session
        )

        let tagged: CancellationTag = "tagged"
        let taggedPath = "/tagged"
        let untaggedPath = "/untagged"

        try await withThrowingTaskGroup(of: (Bool, NetworkError?).self) { group in
            group.addTask { [client] in
                let result: (Bool, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(path: taggedPath), tag: tagged)
                    result = (true, nil)
                } catch let error as NetworkError {
                    result = (true, error)
                } catch {
                    result = (true, .underlying(SendableUnderlyingError(error), nil))
                }
                return result
            }
            group.addTask { [client] in
                let result: (Bool, NetworkError?)
                do {
                    _ = try await client.request(LongPollRequest(path: untaggedPath))
                    result = (false, nil)
                } catch let error as NetworkError {
                    result = (false, error)
                } catch {
                    result = (false, .underlying(SendableUnderlyingError(error), nil))
                }
                return result
            }

            await session.waitUntilStarted(count: 2)

            await client.cancelAll(matching: tagged)
            await session.waitUntilCancelled(path: taggedPath)
            session.succeed(path: untaggedPath)

            var taggedCancelled = false
            var untaggedSucceeded = false
            for try await (isTagged, error) in group {
                if isTagged {
                    if case .cancelled = error {
                        taggedCancelled = true
                    } else {
                        Issue.record("Expected tagged request cancellation, got \(String(describing: error))")
                    }
                } else {
                    if error == nil {
                        untaggedSucceeded = true
                    } else {
                        Issue.record("Expected untagged request success, got \(String(describing: error))")
                    }
                }
            }
            #expect(taggedCancelled)
            #expect(untaggedSucceeded)
        }
    }

    @Test("request(_:tag:) with nil tag behaves identically to request(_:)")
    func requestWithNilTagBehavesAsUntagged() async throws {
        let session = HangingSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com"),
            session: session
        )
        let nilTagPath = "/nil-tag"

        try await withThrowingTaskGroup(of: NetworkError?.self) { group in
            group.addTask {
                do {
                    _ = try await client.request(LongPollRequest(path: nilTagPath), tag: nil)
                    return nil
                } catch let error as NetworkError {
                    return error
                } catch {
                    return .underlying(SendableUnderlyingError(error), nil)
                }
            }

            await session.waitUntilStarted(path: nilTagPath)

            // cancelAll(matching:) with an unrelated tag must not interrupt
            // an untagged request.
            await client.cancelAll(matching: "unrelated")
            session.succeed(path: nilTagPath)

            for try await error in group {
                if error != nil {
                    Issue.record("Expected nil-tag request success, got \(String(describing: error))")
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
