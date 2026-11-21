import Foundation
import Testing

@testable import InnoNetwork

@Suite("Chunked transfer bridge")
struct ChunkedTransferBridgeTests {
    // Foundation reports a data task cancelled before `resume()` (by a caller
    // that was already cancelled, or by session invalidation) as complete on
    // its own queue, and `resume()` cannot restart it afterwards. When that
    // report wins the race against `start(task:)`, the bridge must not wait
    // for a response that will never come.
    @Test(
        "A task that reported completion before its response is awaited fails instead of waiting forever",
        .timeLimit(.minutes(1))
    )
    func completionBeforeTheWaitFails() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try #require(URL(string: "https://early-completion.example.invalid/")))
        let bridge = ChunkedTransferBridge(
            forwardingPolicyCallbacksTo: RequestTaskDelegate(
                request: request,
                context: NetworkRequestContext(),
                sessionHeaderNames: []
            ),
            maxBytes: nil,
            collectsWholeBody: false
        )
        let task = session.dataTask(with: request)

        bridge.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        // The wait runs in its own task: a regression never resumes it, and
        // Swift Testing's time limit cannot end a suspended continuation, so
        // awaiting it inline would hold the whole test run open.
        let (outcomes, report) = AsyncStream.makeStream(of: WaitOutcome.self)
        Task {
            do {
                _ = try await bridge.start(task: task)
                report.yield(.returned)
            } catch {
                report.yield(.threw(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(10))
            report.yield(.timedOut)
        }
        defer { timer.cancel() }
        var iterator = outcomes.makeAsyncIterator()

        switch await iterator.next() {
        case .threw(let error as URLError):
            #expect(error.code == .cancelled)
        case .threw(let error):
            Issue.record("Unexpected error: \(error)")
        case .returned:
            Issue.record("A task that already completed must not deliver a response")
        case .timedOut, nil:
            Issue.record("The wait for a response that will never come did not end")
        }
        // The bridge never started the task; dropping its stream cancelled it.
        #expect(task.state != .running)
    }
}

private enum WaitOutcome: Sendable {
    case returned
    case threw(any Error)
    case timedOut
}
