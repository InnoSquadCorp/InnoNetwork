import Foundation
import os
import Testing
@testable import InnoNetwork
@testable import InnoNetworkDownload


/// Retry behavior verified through the `StubDownloadURLSession` harness.
/// The previous `.invalid` URL + real URLSession race is gone; each retry
/// consumes one pre-queued `StubDownloadURLTask` and completions are
/// injected via the package-level delegate callback directly.
/// `.serialized` because each test drives a 3-attempt retry chain through
/// async `handleCompletion` → `failureCoordinator.handleError` →
/// `transferCoordinator.startDownload` cascades. When the full suite runs
/// these in parallel with the rest of the Download tests, cooperative pool
/// contention can push the multi-step chains past the assertion timeouts.
/// Serializing within this suite alone keeps parallelism across other
/// suites while eliminating the inter-test races.
@Suite("Download Retry Tests", .serialized)
struct DownloadRetryTests {

    @Test("Retry chain stops at maxRetryCount with terminal failed state")
    func retryChainStopsAtMaxRetryCount() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 2,
            maxTotalRetries: 5,
            retryDelay: 0,
            label: "retry-chain"
        )
        // Each failure round creates a new URL task, so pre-queue enough
        // stubs to cover every attempt (initial + maxRetryCount retries).
        for _ in 0..<2 {
            harness.stubSession.enqueue(StubDownloadURLTask())
        }

        let task = await harness.startDownload()

        // Drive `maxRetryCount + 1` failures (initial attempt + retries).
        // Track the *most recent* identifier, not the max seen — the
        // stub's taskIdentifier is random so `sorted().last` would lie.
        var lastIdentifier: Int?
        for _ in 0..<3 {
            let identifier = try #require(await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                excluding: lastIdentifier,
                timeout: 5.0
            ))
            lastIdentifier = identifier
            harness.injectCompletion(
                taskIdentifier: identifier,
                location: nil,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                )
            )
        }

        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .failed })
        #expect(await task.retryCount >= 2)
    }

    @Test("Cancelled transport error does not trigger retry")
    func cancelledTransportErrorSkipsRetry() async throws {
        let harness = try StubDownloadHarness(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            label: "retry-cancelled"
        )
        let task = await harness.startDownload()

        let identifier = try #require(await waitForRuntimeTaskIdentifier(
            manager: harness.manager,
            task: task,
            excluding: nil,
            timeout: 2.0
        ))

        harness.injectCompletion(
            taskIdentifier: identifier,
            location: nil,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.cancelled.rawValue,
                message: "cancelled"
            )
        )

        // Give the failure coordinator a short window to (not) react. The
        // cancelled-transport path short-circuits before retry scheduling,
        // so no new runtime task is created.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await task.retryCount == 0)
        #expect(await task.state != .failed)
        #expect(harness.stubSession.createdTasks.count == 1)

        await harness.manager.cancel(task)
    }

    @Test("Network change resets retry count when waitsForNetworkChanges is enabled")
    func networkChangeResetsRetryCount() async throws {
        let initialSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        let changedSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular])
        let monitor = MockNetworkMonitor(
            currentSnapshot: initialSnapshot,
            nextChangeSnapshot: changedSnapshot
        )

        let harness = try StubDownloadHarness(
            maxRetryCount: 5,
            maxTotalRetries: 10,
            retryDelay: 0,
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 0.5,
            label: "retry-netchange"
        )
        harness.stubSession.enqueue(StubDownloadURLTask()) // retry stub
        let task = await harness.startDownload()

        let firstIdentifier = try #require(await waitForRuntimeTaskIdentifier(
            manager: harness.manager,
            task: task,
            excluding: nil,
            timeout: 2.0
        ))

        harness.injectCompletion(
            taskIdentifier: firstIdentifier,
            location: nil,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "net lost"
            )
        )

        _ = try #require(await waitForRuntimeTaskIdentifier(
            manager: harness.manager,
            task: task,
            excluding: firstIdentifier,
            timeout: 2.0
        ))
        #expect(await monitor.waitForChangeCallCount >= 1)
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount >= 1)

        await harness.manager.cancel(task)
    }

    @Test("maxTotalRetries cap enforces terminal failure even after network resets")
    func maxTotalRetriesCapEnforced() async throws {
        let initialSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        let changedSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular])
        let monitor = MockNetworkMonitor(
            currentSnapshot: initialSnapshot,
            nextChangeSnapshot: changedSnapshot
        )

        let harness = try StubDownloadHarness(
            maxRetryCount: 10,
            maxTotalRetries: 2,
            retryDelay: 0,
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 0.5,
            label: "retry-total-cap"
        )
        // Pre-queue `maxTotalRetries` additional stubs; after the cap is hit
        // the manager must transition to `.failed` instead of asking for one
        // more download task.
        for _ in 0..<2 {
            harness.stubSession.enqueue(StubDownloadURLTask())
        }
        let task = await harness.startDownload()

        var lastIdentifier: Int?
        for _ in 0..<3 {
            let identifier = try #require(await waitForRuntimeTaskIdentifier(
                manager: harness.manager,
                task: task,
                excluding: lastIdentifier,
                timeout: 5.0
            ))
            lastIdentifier = identifier
            harness.injectCompletion(
                taskIdentifier: identifier,
                location: nil,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "net lost"
                )
            )
        }

        #expect(await waitForTaskState(task, timeout: 5.0) { $0 == .failed })
        #expect(await task.totalRetryCount >= 2)
    }
}
