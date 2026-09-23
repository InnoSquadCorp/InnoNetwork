import Foundation
import Testing

@testable import InnoNetworkUpload

@Suite("Upload pending event integrity", .serialized, .timeLimit(.minutes(1)))
struct UploadPendingEventIntegrityTests {
    private static func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://upload.example.test/file")!)
        request.httpMethod = "POST"
        return request
    }

    private static func drain(
        _ manager: UploadManager,
        _ channel: UploadDelegateEventChannel
    ) async {
        await withCheckedContinuation { continuation in
            manager.handleBackgroundEvents { continuation.resume() }
            channel.send(.backgroundEventsFinished)
        }
    }

    private static func complete(
        _ channel: UploadDelegateEventChannel,
        identifier: Int,
        logicalID: String,
        request: URLRequest
    ) {
        channel.send(
            .completed(
                taskIdentifier: identifier,
                taskDescription: logicalID,
                originalRequest: request,
                currentRequest: request,
                response: HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ),
                error: nil
            )
        )
    }

    @Test(
        "Exceeding pending event capacity fails instead of returning a truncated receipt",
        arguments: [1, 512]
    )
    func pendingBodyOverflowFailsClosed(limit: Int) async throws {
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 4,
            maximumBufferedDelegateEvents: limit,
            maximumBufferedDelegateBytes: 2_097_152,
            maximumPendingUnknownTasks: 4
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        let session = StubUploadURLSession(channel: channel)
        let manager = UploadManager(
            configuration: .background(
                sessionIdentifier: "test.pending.body.\(limit)", resourcePolicy: policy
            ),
            session: session,
            channel: channel
        )
        for _ in 0...limit {
            channel.send(.data(taskIdentifier: 71, data: Data([65])))
            await Self.drain(manager, channel)
        }
        Self.complete(channel, identifier: 71, logicalID: "pending-body", request: Self.request())
        await Self.drain(manager, channel)

        let task = try #require(await manager.task(withId: "pending-body"))
        #expect(await task.state == .failed)
        #expect(await task.error == .delegateBufferExceeded(limit: limit))
        #expect(await task.receipt == nil)
        await manager.shutdown()
    }

    @Test("Unknown-task capacity overflow cannot lose response data silently")
    func unknownTaskCapacityFailsClosed() async throws {
        let policy = UploadResourcePolicy(
            maximumTrackedTasks: 4,
            maximumBufferedDelegateEvents: 4,
            maximumBufferedDelegateBytes: 1_024,
            maximumPendingUnknownTasks: 1
        )
        let channel = UploadDelegateEventChannel(limits: policy)
        let session = StubUploadURLSession(channel: channel)
        let manager = UploadManager(
            configuration: .background(
                sessionIdentifier: "test.pending.unknown", resourcePolicy: policy
            ),
            session: session,
            channel: channel
        )
        channel.send(.data(taskIdentifier: 71, data: Data([65])))
        await Self.drain(manager, channel)
        channel.send(.data(taskIdentifier: 72, data: Data([66])))
        await Self.drain(manager, channel)
        Self.complete(channel, identifier: 71, logicalID: "first", request: Self.request())
        await Self.drain(manager, channel)

        let task = try #require(await manager.task(withId: "first"))
        #expect(await task.state == .failed)
        #expect(await task.error == .delegateBufferExceeded(limit: 1))
        #expect(await task.receipt == nil)
        await manager.shutdown()
    }
}
