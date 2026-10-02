import Foundation
import InnoNetwork
import Testing
import os

@testable import InnoNetworkUpload

@Suite("Upload terminal and retry ordering", .serialized)
struct UploadTerminalRetryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func retryWaitsForPreviousTerminalDelivery(
        statusFailure: Bool,
        cancelWaitingRetry: Bool
    ) async throws {
        let gate = UploadTerminalPublicationGate()
        defer { gate.open() }
        let (manager, session, channel) = makeUploadHarness(
            terminalPublicationHook: { await gate.waitOnce() }
        )
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var mutableRequest = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        mutableRequest.httpMethod = "POST"
        mutableRequest.setValue("terminal-retry", forHTTPHeaderField: "Idempotency-Key")
        let request = mutableRequest
        let operation = try await manager.upload(request, fromFile: file)
        let original = try #require(session.latestTask)
        channel.send(
            .completed(
                taskIdentifier: original.taskIdentifier,
                taskDescription: original.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: statusFailure
                    ? HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)
                    : nil,
                error: statusFailure ? nil : SendableUnderlyingError(URLError(.networkConnectionLost))
            )
        )
        await gate.waitUntilEntered()
        #expect(await operation.task.state == .failed)

        let retry = Task { try await manager.retry(operation.task, with: request, fromFile: file) }
        await withTaskCancellationHandler {
            // Observe actual retry admission or its registered terminal waiter.
            // A scheduler yield by itself is never treated as that evidence.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while session.taskCount == 1,
                await manager.pendingTerminalRetryWaiterCount == 0,
                ContinuousClock.now < deadline,
                !Task.isCancelled
            {
                await Task.yield()
            }
            #expect(await manager.pendingTerminalRetryWaiterCount == 1)
            #expect(session.taskCount == 1)
            await #expect(throws: UploadError.invalidRequest("An upload retry is already being prepared")) {
                _ = try await manager.retry(operation.task, with: request, fromFile: file)
            }
            #expect(await manager.pendingTerminalRetryWaiterCount == 1)
            if cancelWaitingRetry {
                retry.cancel()
                let result = await retry.result
                if case .failure(let error) = result {
                    #expect(error as? UploadError == .cancelled)
                } else {
                    Issue.record("A cancelled terminal waiter started another upload")
                }
                #expect(await manager.pendingTerminalRetryWaiterCount == 0)
                gate.open()
            } else {
                gate.open()
                do {
                    let retried = try await retry.value
                    let systemTask = try #require(session.latestTask)
                    #expect(systemTask.taskIdentifier != original.taskIdentifier)
                    channel.send(
                        .completed(
                            taskIdentifier: systemTask.taskIdentifier,
                            taskDescription: systemTask.taskDescription,
                            originalRequest: request,
                            currentRequest: request,
                            response: HTTPURLResponse(
                                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
                            ),
                            error: nil
                        )
                    )
                    let drained = AsyncStream<Void>.makeStream()
                    manager.handleBackgroundEvents { drained.continuation.finish() }
                    channel.send(.backgroundEventsFinished)
                    for await _ in drained.stream {}
                    let finalState = await retried.task.state
                    #expect(finalState == .completed)
                    if finalState != .completed { await manager.cancel(retried.task) }
                    var receivedStatus: Int?
                    for await event in retried.events {
                        if case .completed(let receipt) = event { receivedStatus = receipt.response.statusCode }
                    }
                    #expect(receivedStatus == 201)
                    #expect(await retried.task.state == .completed)
                } catch {
                    Issue.record("Retry failed: \(error)")
                }
            }
        } onCancel: {
            retry.cancel()
            gate.open()
        }
        gate.open()
        _ = await retry.result
        await manager.shutdown()
    }
}

private final class UploadTerminalPublicationGate: Sendable {
    private let first = OSAllocatedUnfairLock(initialState: true)
    private let entered = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    func waitOnce() async {
        guard
            first.withLock({ value in
                let result = value
                value = false
                return result
            })
        else { return }
        entered.continuation.finish()
        for await _ in release.stream {}
    }

    func waitUntilEntered() async {
        for await _ in entered.stream {}
    }

    func open() { release.continuation.finish() }
}
