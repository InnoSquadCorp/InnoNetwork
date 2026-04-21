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

    @Test("Cancelling the retry task while sleeping suppresses restart")
    func cancelledRetryTaskDoesNotRestart() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 1.0,
            sessionIdentifier: "test.retry-task-cancel.\(UUID().uuidString)"
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
                    message: "cancelled while sleeping"
                ),
                restart: { _ in
                    restartCounter.withLock { $0 += 1 }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        handleTask.cancel()

        await handleTask.value
        #expect(clock.waiterCount == 0)
        #expect(restartCounter.withLock { $0 } == 0)
    }

    @Test("Exponential backoff disabled (default) reuses the fixed retryDelay on every cycle")
    func exponentialBackoffDisabledUsesFixedDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 2.0,
            exponentialBackoff: false,
            sessionIdentifier: "test.retry-exp-off.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )
        // Pre-inflate the retry counter so the second cycle would use
        // exponent 2 if exp backoff were active. Since it's disabled we
        // must see the plain 2.0s delay.
        _ = await task.incrementRetryCount()

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
        // Half the fixed delay — must still be pending.
        clock.advance(by: .seconds(1))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(restartCounter.withLock { $0 } == 0)
        // Cross the remaining slack — delay is exactly 2.0s.
        clock.advance(by: .seconds(1.1))
        await handleTask.value
        #expect(restartCounter.withLock { $0 } == 1)
    }

    @Test("Exponential backoff enabled doubles the delay each retry cycle")
    func exponentialBackoffEnabledDoublesDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 5,
            maxTotalRetries: 5,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 0,
            sessionIdentifier: "test.retry-exp-on.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        // retryCount=1 → delay = 1 * 2^0 = 1s
        // retryCount=2 → delay = 1 * 2^1 = 2s
        // retryCount=3 → delay = 1 * 2^2 = 4s
        let expected: [TimeInterval] = [1, 2, 4]
        for (index, seconds) in expected.enumerated() {
            // Align the task's retryCount to what the coordinator will see
            // after its `incrementRetryCount` inside this cycle.
            while await task.retryCount < index {
                _ = await task.incrementRetryCount()
            }

            let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
            let handleTask = Task {
                await coordinator.handleError(
                    task: task,
                    error: SendableUnderlyingError(
                        domain: NSURLErrorDomain,
                        code: URLError.networkConnectionLost.rawValue,
                        message: "cycle-\(index)"
                    ),
                    restart: { _ in
                        restarted.withLock { $0 = true }
                    }
                )
            }

            #expect(await clock.waitForWaiters(count: 1))
            clock.advance(by: .seconds(seconds))
            await handleTask.value
            #expect(
                restarted.withLock { $0 },
                "cycle \(index): expected delay \(seconds)s to unblock restart"
            )
        }
    }

    @Test("maxRetryDelay caps the exponential backoff delay")
    func exponentialBackoffCapsAtMaxRetryDelay() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 20,
            maxTotalRetries: 20,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 5.0,
            sessionIdentifier: "test.retry-cap.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )
        // retryCount=10 → unclamped = 1 * 2^9 = 512s. Cap pins it at 5s.
        for _ in 0..<9 {
            _ = await task.incrementRetryCount()
        }

        let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "cap"
                ),
                restart: { _ in
                    restarted.withLock { $0 = true }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5.001))
        await handleTask.value
        #expect(restarted.withLock { $0 })
    }

    @Test("maxRetryDelay <= 0 disables the cap")
    func maxRetryDelayZeroDisablesCap() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: 10,
            maxTotalRetries: 10,
            retryDelay: 2.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 0,
            sessionIdentifier: "test.retry-uncap.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )
        // retryCount=3 → delay = 2 * 2^2 = 8s. 5s advance leaves the waiter
        // pending — cap is disabled so there is no clamp.
        for _ in 0..<2 {
            _ = await task.incrementRetryCount()
        }

        let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "uncap"
                ),
                restart: { _ in
                    restarted.withLock { $0 = true }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(restarted.withLock { $0 } == false, "5s advance should not unblock an 8s unclamped delay")
        clock.advance(by: .seconds(4))
        await handleTask.value
        #expect(restarted.withLock { $0 })
    }

    @Test("Huge retry counts stay finite when maxRetryDelay caps the backoff")
    func hugeRetryCountRemainsFiniteWhenCapped() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: Int.max,
            maxTotalRetries: Int.max,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 5.0,
            sessionIdentifier: "test.retry-huge-capped.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        await task.setRetryCount(Int.max - 2)

        let restarted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "huge-capped"
                ),
                restart: { _ in
                    restarted.withLock { $0 = true }
                }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5.001))
        await handleTask.value
        #expect(restarted.withLock { $0 })
    }

    @Test("Huge retry counts still enqueue a finite wait when the user-facing cap is disabled")
    func hugeRetryCountWithoutUserCapStillEnqueuesFiniteWait() async throws {
        let clock = TestClock()
        let configuration = DownloadConfiguration(
            maxRetryCount: Int.max,
            maxTotalRetries: Int.max,
            retryDelay: 1.0,
            exponentialBackoff: true,
            retryJitterRatio: 0.0,
            maxRetryDelay: 0,
            sessionIdentifier: "test.retry-huge-uncapped.\(UUID().uuidString)"
        )
        let (coordinator, task) = await makeCoordinator(
            configuration: configuration,
            clock: clock
        )

        await task.setRetryCount(Int.max - 2)

        let handleTask = Task {
            await coordinator.handleError(
                task: task,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "huge-uncapped"
                ),
                restart: { _ in }
            )
        }

        #expect(await clock.waitForWaiters(count: 1))
        await task.updateState(.cancelled)
        handleTask.cancel()
        await handleTask.value
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


// `InMemoryDownloadTaskStore` lives in its own file now so the pause/resume,
// restore, retry, and retry-timing suites can all seed persistence from the
// same implementation.
