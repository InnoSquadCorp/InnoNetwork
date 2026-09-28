import Foundation
import InnoNetwork
import Testing
import os

@testable import InnoNetworkUpload

@Suite("Upload identifier retention", .serialized, .timeLimit(.minutes(1)))
struct UploadIdentifierRetentionTests {
    @Test("terminal identifiers stay exact for contiguous and sparse long runs", arguments: [1, 2])
    func statelessSessionLongRun(identifierStride: Int) async throws {
        let iterations = Int(ProcessInfo.processInfo.environment["INNO_UPLOAD_SOAK_ITERATIONS"] ?? "1000") ?? 0
        try #require((1...100_000).contains(iterations), "Soak iterations must be between 1 and 100000")
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 1,
            maximumBufferedDelegateEvents: 4,
            maximumBufferedDelegateBytes: 1_024,
            maximumPendingUnknownTasks: 1,
            maximumRetainedTerminalTasks: 0,
            maximumIdentifierRanges: iterations
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        let session = StatelessUploadURLSession(channel: channel, identifierStride: identifierStride)
        let manager = UploadManager(
            configuration: .advanced(resourcePolicy: policy),
            session: session,
            channel: channel
        )
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/file")!)
        request.httpMethod = "POST"
        let response = try #require(
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        )

        for _ in 0..<iterations {
            let operation = try await manager.upload(request, fromFile: file)
            channel.send(
                .completed(
                    taskIdentifier: session.lastIdentifier,
                    taskDescription: operation.task.id,
                    originalRequest: request,
                    currentRequest: request,
                    response: response,
                    error: nil
                )
            )
            await withCheckedContinuation { continuation in
                manager.handleBackgroundEvents { continuation.resume() }
                channel.send(.backgroundEventsFinished)
            }
            #expect(await manager.allTasks().isEmpty)
        }

        #expect(await manager.retainedSystemIdentifierRangeCount == (identifierStride == 1 ? 1 : iterations))
        // A late callback must not recreate an already retired task, including
        // one of the early sparse IDs that a lossy high-water mark would forget.
        channel.send(
            .completed(
                taskIdentifier: identifierStride,
                taskDescription: "late-terminal",
                originalRequest: request,
                currentRequest: request,
                response: response,
                error: nil
            )
        )
        await withCheckedContinuation { continuation in
            manager.handleBackgroundEvents { continuation.resume() }
            channel.send(.backgroundEventsFinished)
        }
        #expect(await manager.allTasks().isEmpty)
        await manager.shutdown()
        #expect(await manager.retainedSystemIdentifierRangeCount == 0)
    }

    @Test("channel overflow history stays exact until finish", arguments: [1, 2])
    func channelOverflowLongRun(identifierStride: Int) async throws {
        let iterations = Int(ProcessInfo.processInfo.environment["INNO_UPLOAD_SOAK_ITERATIONS"] ?? "1000") ?? 0
        try #require((1...100_000).contains(iterations), "Soak iterations must be between 1 and 100000")
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 1,
            maximumBufferedDelegateEvents: 1,
            maximumBufferedDelegateBytes: 1,
            maximumPendingUnknownTasks: 1,
            maximumIdentifierRanges: iterations
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        for index in 1...iterations {
            let identifier = index * identifierStride
            channel.send(.data(taskIdentifier: identifier, data: Data([1, 2])))
            guard case .overflow(let actual, _) = await channel.next() else {
                Issue.record("Expected overflow for task \(identifier)")
                return
            }
            #expect(actual == identifier)
        }
        #expect(channel.overflowedIdentifierRangeCount == (identifierStride == 1 ? 1 : iterations))
        channel.finish()
        #expect(channel.overflowedIdentifierRangeCount == 0)
        channel.send(.data(taskIdentifier: 2_001, data: Data([1, 2])))
        #expect(await channel.next() == nil)
        #expect(channel.overflowedIdentifierRangeCount == 0)
    }

    @Test("sparse history exhaustion rejects admissions but drains registered tasks")
    func boundedSparseHistory() async throws {
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 4, maximumBufferedDelegateEvents: 16,
            maximumBufferedDelegateBytes: 1024, maximumPendingUnknownTasks: 4,
            maximumRetainedTerminalTasks: 0, maximumIdentifierRanges: 1
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        let session = StatelessUploadURLSession(channel: channel, identifierStride: 2)
        let manager = UploadManager(
            configuration: .background(sessionIdentifier: "bounded-history", resourcePolicy: policy),
            session: session, channel: channel
        )
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/file")!)
        request.httpMethod = "POST"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for _ in 0..<3 { _ = try await manager.upload(request, fromFile: file) }
        for identifier in [2, 4, 6, 4, 2] {
            channel.send(
                .completed(
                    taskIdentifier: identifier, taskDescription: "late",
                    originalRequest: request, currentRequest: request, response: response, error: nil))
            await withCheckedContinuation { continuation in
                manager.handleBackgroundEvents { continuation.resume() }
                channel.send(.backgroundEventsFinished)
            }
        }
        #expect(await manager.retainedSystemIdentifierRangeCount == 1)
        #expect(await manager.allTasks().isEmpty)
        await #expect(throws: UploadError.resourceLimitExceeded(limit: 1)) {
            try await manager.upload(request, fromFile: file)
        }
        #expect(session.lastIdentifier == 6)
        await manager.shutdown()
    }

    @Test("overflow history exhaustion fails closed and preserves lifecycle acknowledgements")
    func boundedOverflowHistory() async {
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 1, maximumBufferedDelegateEvents: 1,
            maximumBufferedDelegateBytes: 1, maximumPendingUnknownTasks: 1,
            maximumIdentifierRanges: 1
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        channel.send(.data(taskIdentifier: 2, data: Data([1, 2])))
        guard case .overflow = await channel.next() else {
            Issue.record("Expected overflow")
            return
        }
        channel.send(.data(taskIdentifier: 4, data: Data([1, 2])))
        guard case .capacityExceeded = await channel.next() else {
            Issue.record("Expected bounded failure")
            return
        }
        for id in 0..<10_000 { channel.send(.data(taskIdentifier: id, data: Data([1, 2]))) }
        channel.send(.invalidated)
        guard case .invalidated = await channel.next() else {
            Issue.record("Lost lifecycle event")
            return
        }
        #expect(channel.overflowedIdentifierRangeCount == 1)
        channel.finish()
    }

    @Test("delegate capacity failure cancels active tasks and reports the exhausted bound")
    func capacityFailureTerminatesRegisteredTasks() async throws {
        let channel = UploadDelegateEventChannel()
        let session = StatelessUploadURLSession(channel: channel)
        let manager = UploadManager(configuration: .safeDefaults(), session: session, channel: channel)
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/file")!)
        request.httpMethod = "POST"
        let operation = try await manager.upload(request, fromFile: file)
        channel.send(.capacityExceeded(limit: 3))
        await withCheckedContinuation { continuation in
            manager.handleBackgroundEvents { continuation.resume() }
            channel.send(.backgroundEventsFinished)
        }
        #expect(await operation.task.error == .delegateBufferExceeded(limit: 3))
        await #expect(throws: UploadError.delegateBufferExceeded(limit: 3)) {
            try await manager.upload(request, fromFile: file)
        }
        #expect(session.lastIdentifier == 1)
        await manager.shutdown()
    }
}

private final class StatelessUploadURLSession: UploadURLSession, @unchecked Sendable {
    private let nextIdentifier = OSAllocatedUnfairLock(initialState: 0)
    private let channel: UploadDelegateEventChannel
    private let identifierStride: Int

    init(channel: UploadDelegateEventChannel, identifierStride: Int = 1) {
        self.channel = channel
        self.identifierStride = identifierStride
    }

    var lastIdentifier: Int { nextIdentifier.withLock { $0 } }

    func makeUploadTask(with request: URLRequest, fromFile _: URL) -> any UploadURLTask {
        let identifier = nextIdentifier.withLock { value -> Int in
            value += identifierStride
            return value
        }
        return StubUploadURLTask(taskIdentifier: identifier, request: request)
    }

    func allUploadTasks() async -> [any UploadURLTask] { [] }

    func invalidateAndCancel() {
        channel.send(.invalidated)
    }
}
