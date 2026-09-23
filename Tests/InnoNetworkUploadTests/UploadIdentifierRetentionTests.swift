import Foundation
import InnoNetwork
import Testing
import os

@testable import InnoNetworkUpload

@Suite("Upload identifier retention", .serialized, .timeLimit(.minutes(1)))
struct UploadIdentifierRetentionTests {
    @Test("terminal identifiers stay exact without one allocation per sequential task")
    func statelessSessionLongRun() async throws {
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 1,
            maximumBufferedDelegateEvents: 4,
            maximumBufferedDelegateBytes: 1_024,
            maximumPendingUnknownTasks: 1,
            maximumRetainedTerminalTasks: 0
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        let session = StatelessUploadURLSession(channel: channel)
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

        for _ in 0..<1_000 {
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

        #expect(await manager.retainedSystemIdentifierRangeCount == 1)
        await manager.shutdown()
    }

    @Test("channel overflow markers compress across sequential tasks")
    func channelOverflowLongRun() async {
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 1,
            maximumBufferedDelegateEvents: 1,
            maximumBufferedDelegateBytes: 1,
            maximumPendingUnknownTasks: 1
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        for identifier in 1...1_000 {
            channel.send(.data(taskIdentifier: identifier, data: Data([1, 2])))
            guard case .overflow(let actual, _) = await channel.next() else {
                Issue.record("Expected overflow for task \(identifier)")
                return
            }
            #expect(actual == identifier)
        }
        #expect(channel.overflowedIdentifierRangeCount == 1)
        channel.finish()
    }
}

private final class StatelessUploadURLSession: UploadURLSession, @unchecked Sendable {
    private let nextIdentifier = OSAllocatedUnfairLock(initialState: 0)
    private let channel: UploadDelegateEventChannel

    init(channel: UploadDelegateEventChannel) {
        self.channel = channel
    }

    var lastIdentifier: Int { nextIdentifier.withLock { $0 } }

    func makeUploadTask(with request: URLRequest, fromFile _: URL) -> any UploadURLTask {
        let identifier = nextIdentifier.withLock { value -> Int in
            value += 1
            return value
        }
        return StubUploadURLTask(taskIdentifier: identifier, request: request)
    }

    func allUploadTasks() async -> [any UploadURLTask] { [] }

    func invalidateAndCancel() {
        channel.send(.invalidated)
    }
}
