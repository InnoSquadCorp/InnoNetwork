import Foundation
import os
import Testing
import InnoNetworkTestSupport
@testable import InnoNetwork
@testable import InnoNetworkDownload


/// Deterministic timing tests for `DownloadFailureCoordinator`. Drives the
/// coordinator directly (no URLSession / no DownloadManager) so the retry
/// delay path is exercised against a virtual-time `TestClock` instead of
/// `Task.sleep` wall-clock. Complements the integration-oriented
/// `DownloadRetryTests` suite, which keeps `retryDelay: 0` to avoid real
/// sleeps.
@Suite("Download Retry Timing Tests")
struct DownloadRetryTimingTests {

    @Test("retryDelay > 0 suspends on the injected clock until advance fires")
    func retryDelayRespectsInjectedClock() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 2.0,
            sessionIdentifier: "test.retry-timing.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "connection lost"
                ),
                restart: { _ in
                    restartCounter.withLock { $0 += 1 }
                }
            )
        }

        // Coordinator bumps retry counters synchronously and then enqueues a
        // single waiter on the virtual clock.
        #expect(await clock.waitForWaiters(count: 1))
        #expect(restartCounter.withLock { $0 } == 0)
        #expect(await task.retryCount == 1)
        #expect(await task.totalRetryCount == 1)

        // Until advance, restart must not have fired.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(restartCounter.withLock { $0 } == 0)

        // Advance past the retryDelay -> waiter resumes -> restart fires.
        clock.advance(by: .seconds(2))
        await handleTask.value
        #expect(restartCounter.withLock { $0 } == 1)
    }

    @Test("retryDelay == 0 skips the clock entirely")
    func zeroDelayRetryFiresImmediately() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            sessionIdentifier: "test.retry-zero.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

        await coordinator.handleError(
            task: task,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "net lost"
            ),
            restart: { _ in
                restartCounter.withLock { $0 += 1 }
            }
        )

        #expect(clock.enqueuedCount == 0)
        #expect(restartCounter.withLock { $0 } == 1)
        #expect(await task.retryCount == 1)
    }

    @Test("Cancelled task skips restart after clock advance")
    func cancelledTaskSuppressesRestartAfterDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 1.0,
            sessionIdentifier: "test.retry-cancel.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        let restartCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "net lost"
                ),
                restart: { _ in
                    restartCounter.withLock { $0 += 1 }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        await task.updateState(.cancelled)
        clock.advance(by: .seconds(1))

        await handleTask.value
        #expect(restartCounter.withLock { $0 } == 0)
    }
}


// MARK: - Helpers

@MainActor
private func makeCoordinator(
    configuration: DownloadConfiguration,
    clock: TestClock
) async -> (DownloadFailureCoordinator, DownloadTask) {
    let runtimeRegistry = DownloadRuntimeRegistry()
    let persistence = DownloadTaskPersistence(store: InMemoryDownloadTaskStore())
    let eventHub = TaskEventHub<DownloadEvent>(
        policy: configuration.eventDeliveryPolicy,
        metricsReporter: configuration.eventMetricsReporter,
        hubKind: .downloadTask
    )
    let coordinator = DownloadFailureCoordinator(
        configuration: configuration,
        runtimeRegistry: runtimeRegistry,
        persistence: persistence,
        eventHub: eventHub,
        clock: clock
    )
    let task = DownloadTask(
        url: URL(string: "https://example.invalid/test.bin")!,
        destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).bin")
    )
    await runtimeRegistry.add(task)
    return (coordinator, task)
}


/// Minimal in-memory `DownloadTaskStore` so the timing tests do not write to
/// disk via the production `AppendLogDownloadTaskStore`. The retry path only
/// calls `remove(id:)` on the terminal-failure branch, so the other methods
/// return sensible defaults for any call we might make from `handleError`.
private actor InMemoryDownloadTaskStore: DownloadTaskStore {
    private var records: [String: DownloadTaskPersistence.Record] = [:]

    func upsert(id: String, url: URL, destinationURL: URL) async {
        records[id] = DownloadTaskPersistence.Record(
            id: id,
            url: url,
            destinationURL: destinationURL
        )
    }

    func remove(id: String) async {
        records.removeValue(forKey: id)
    }

    func record(forID id: String) async -> DownloadTaskPersistence.Record? {
        records[id]
    }

    func allRecords() async -> [DownloadTaskPersistence.Record] {
        Array(records.values)
    }

    func id(forURL url: URL?) async -> String? {
        guard let url else { return nil }
        return records.values.first(where: { $0.url == url })?.id
    }

    func prune(keeping ids: Set<String>) async {
        records = records.filter { ids.contains($0.key) }
    }
}
