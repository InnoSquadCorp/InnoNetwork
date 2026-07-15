import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Runtime Registry Tests")
struct DownloadRuntimeRegistryTests {
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
