import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Runtime Registry Tests")
struct DownloadRuntimeRegistryTests {
    @Test("Runtime registration is observable before the separate downloading transition")
    func registrationDoesNotCompleteLifecycleTransition() async throws {
        let registry = DownloadRuntimeRegistry()
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/registry-transition.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )
        try #require(await registry.add(task))
        await task.restoreState(.waiting)
        let waitingLifecycle = await task.lifecycleSnapshot()
        let attempt = StubDownloadURLTask(request: URLRequest(url: task.url))

        // Model the suspension window in startDownload without timing or sleeps:
        // registration has completed, but its next actor call has not run yet.
        #expect(await registry.register(urlTask: attempt, for: task) == nil)
        #expect(await registry.taskIdentifier(for: task.id) == attempt.taskIdentifier)
        #expect(await task.state == .waiting)

        try #require(await task.transition(to: .downloading, ifMatching: waitingLifecycle) != nil)
        #expect(await task.state == .downloading)
        #expect(await registry.taskIdentifier(for: task.id) == attempt.taskIdentifier)
    }

    @Test("Replacing an attempt atomically evicts every edge for its predecessor")
    func replacementEvictsPredecessorEdges() async throws {
        let registry = DownloadRuntimeRegistry()
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/registry.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")
        )
        #expect(await registry.add(task))

        let first = StubDownloadURLTask(
            taskIdentifier: 91_001,
            request: URLRequest(url: task.url)
        )
        let second = StubDownloadURLTask(
            taskIdentifier: 91_002,
            request: URLRequest(url: task.url)
        )

        #expect(await registry.register(urlTask: first, for: task) == nil)
        let displaced = await registry.register(urlTask: second, for: task)

        #expect(displaced?.taskIdentifier == first.taskIdentifier)
        #expect(await registry.downloadTask(for: first.taskIdentifier) == nil)
        #expect(await registry.downloadTask(for: second.taskIdentifier) === task)
        #expect(await registry.taskIdentifier(for: task.id) == second.taskIdentifier)
        #expect(await registry.urlTask(for: task.id)?.taskIdentifier == second.taskIdentifier)

        await registry.removeAttemptRuntime(taskIdentifier: second.taskIdentifier)
        #expect(await registry.downloadTask(for: second.taskIdentifier) == nil)
        #expect(await registry.taskIdentifier(for: task.id) == nil)
        #expect(await registry.urlTask(for: task.id) == nil)
    }
}
