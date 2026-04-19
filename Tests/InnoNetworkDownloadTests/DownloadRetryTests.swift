import Foundation
import Testing
@testable import InnoNetworkDownload


@Suite("Download Retry Tests")
struct DownloadRetryTests {

    @Test("Retry chain stops at maxRetryCount with terminal failed state")
    func retryChainStopsAtMaxRetryCount() async throws {
        let config = DownloadConfiguration(
            maxRetryCount: 2,
            maxTotalRetries: 5,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("retry-chain")
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        var excluded: Set<Int> = []
        var lastIdentifier: Int?
        for _ in 0..<(config.maxRetryCount + 1) {
            let identifier = try #require(await waitForRuntimeIdentifier(
                manager: manager,
                task: task,
                excluding: excluded,
                timeout: 3.0
            ))
            excluded.insert(identifier)
            lastIdentifier = identifier
            await injectSyntheticCompletion(
                manager: manager,
                task: task,
                taskIdentifier: identifier,
                location: nil,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "network lost"
                )
            )
        }

        _ = lastIdentifier
        #expect(await waitForTaskState(task, timeout: 3.0) { $0 == .failed })
        #expect(await task.retryCount >= config.maxRetryCount)
    }

    @Test("Cancelled transport error does not trigger retry")
    func cancelledTransportErrorSkipsRetry() async throws {
        let config = DownloadConfiguration(
            maxRetryCount: 3,
            maxTotalRetries: 3,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("retry-cancelled")
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        let identifier = try #require(await waitForRuntimeIdentifier(
            manager: manager,
            task: task,
            excluding: [],
            timeout: 2.0
        ))

        await injectSyntheticCompletion(
            manager: manager,
            task: task,
            taskIdentifier: identifier,
            location: nil,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.cancelled.rawValue,
                message: "cancelled"
            )
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await task.retryCount == 0)
        #expect(await task.state != .failed)

        await manager.cancel(task)
    }

    @Test("Network change resets retry count when waitsForNetworkChanges is enabled")
    func networkChangeResetsRetryCount() async throws {
        let initialSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        let changedSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular])
        let monitor = MockNetworkMonitor(
            currentSnapshot: initialSnapshot,
            nextChangeSnapshot: changedSnapshot
        )

        let config = DownloadConfiguration(
            maxRetryCount: 5,
            maxTotalRetries: 10,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("retry-netchange"),
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 0.5
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        let firstIdentifier = try #require(await waitForRuntimeIdentifier(
            manager: manager,
            task: task,
            excluding: [],
            timeout: 2.0
        ))

        await injectSyntheticCompletion(
            manager: manager,
            task: task,
            taskIdentifier: firstIdentifier,
            location: nil,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                message: "net lost"
            )
        )

        _ = try #require(await waitForRuntimeIdentifier(
            manager: manager,
            task: task,
            excluding: [firstIdentifier],
            timeout: 3.0
        ))
        #expect(await monitor.waitForChangeCallCount >= 1)
        #expect(await task.retryCount == 0)
        #expect(await task.totalRetryCount >= 1)

        await manager.cancel(task)
    }

    @Test("maxTotalRetries cap enforces terminal failure even after network resets")
    func maxTotalRetriesCapEnforced() async throws {
        let initialSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        let changedSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular])
        let monitor = MockNetworkMonitor(
            currentSnapshot: initialSnapshot,
            nextChangeSnapshot: changedSnapshot
        )

        let config = DownloadConfiguration(
            maxRetryCount: 10,
            maxTotalRetries: 2,
            retryDelay: 0,
            sessionIdentifier: makeDownloadTestSessionIdentifier("retry-total-cap"),
            networkMonitor: monitor,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 0.5
        )
        let manager = try DownloadManager(configuration: config)

        let task = await manager.download(
            url: URL(string: "https://example.invalid/file.zip")!,
            to: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )

        var excluded: Set<Int> = []
        for _ in 0..<(config.maxTotalRetries + 1) {
            let identifier = try #require(await waitForRuntimeIdentifier(
                manager: manager,
                task: task,
                excluding: excluded,
                timeout: 3.0
            ))
            excluded.insert(identifier)
            await injectSyntheticCompletion(
                manager: manager,
                task: task,
                taskIdentifier: identifier,
                location: nil,
                error: SendableUnderlyingError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    message: "net lost"
                )
            )
        }

        #expect(await waitForTaskState(task, timeout: 3.0) { $0 == .failed })
        #expect(await task.totalRetryCount >= config.maxTotalRetries)
    }

    private func waitForRuntimeIdentifier(
        manager: DownloadManager,
        task: DownloadTask,
        excluding: Set<Int>,
        timeout: TimeInterval
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let identifier = await manager.runtimeTaskIdentifier(for: task),
               !excluding.contains(identifier) {
                return identifier
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}
