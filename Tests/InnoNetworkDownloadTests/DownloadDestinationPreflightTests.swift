import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Destination Preflight Tests")
struct DownloadDestinationPreflightTests {
    @Test("non-file destination fails before URLSession task creation")
    func nonFileDestinationFailsBeforeTransportCreation() async throws {
        let harness = try StubDownloadHarness(label: "destination-non-file")
        let task = await harness.startDownload(
            destinationURL: URL(string: "https://example.invalid/output.bin")!
        )

        await expectPreflightFailure(task, harness: harness)
        await harness.manager.shutdown()
    }

    @Test("existing destination directory fails before URLSession task creation")
    func existingDirectoryFailsBeforeTransportCreation() async throws {
        let fileManager = FileManager.default
        let rootURL = makeTemporaryRoot(label: "existing-directory")
        let directoryURL = rootURL.appendingPathComponent("output.bin", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let destinationURL = URL(fileURLWithPath: directoryURL.path, isDirectory: false)
        let harness = try StubDownloadHarness(label: "destination-existing-directory")

        let task = await harness.startDownload(destinationURL: destinationURL)

        await expectPreflightFailure(task, harness: harness)
        await harness.manager.shutdown()
    }

    @Test("file in the parent chain blocks transport creation")
    func blockedParentFileFailsBeforeTransportCreation() async throws {
        let fileManager = FileManager.default
        let rootURL = makeTemporaryRoot(label: "blocked-parent")
        let blockedParentURL = rootURL.appendingPathComponent("not-a-directory", isDirectory: false)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedParentURL)
        defer { try? fileManager.removeItem(at: rootURL) }
        let destinationURL =
            blockedParentURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("output.bin", isDirectory: false)
        let harness = try StubDownloadHarness(label: "destination-blocked-parent")

        let task = await harness.startDownload(destinationURL: destinationURL)

        await expectPreflightFailure(task, harness: harness)
        await harness.manager.shutdown()
    }

    @Test("existing destination symlink fails before URLSession task creation")
    func existingSymlinkFailsBeforeTransportCreation() async throws {
        let fileManager = FileManager.default
        let rootURL = makeTemporaryRoot(label: "existing-symlink")
        let targetURL = rootURL.appendingPathComponent("target.bin", isDirectory: false)
        let destinationURL = rootURL.appendingPathComponent("output.bin", isDirectory: false)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: targetURL)
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: targetURL)
        defer { try? fileManager.removeItem(at: rootURL) }
        let harness = try StubDownloadHarness(label: "destination-existing-symlink")

        let task = await harness.startDownload(destinationURL: destinationURL)

        await expectPreflightFailure(task, harness: harness)
        await harness.manager.shutdown()
    }

    @Test("valid nested destination creates and starts the URLSession task")
    func validNestedDestinationStartsTransport() async throws {
        let fileManager = FileManager.default
        let rootURL = makeTemporaryRoot(label: "valid-nested")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let destinationURL =
            rootURL
            .appendingPathComponent("not-created-yet", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("output.bin", isDirectory: false)
        let harness = try StubDownloadHarness(label: "destination-valid-nested")

        let task = await harness.startDownload(destinationURL: destinationURL)

        #expect(await task.state == .downloading)
        #expect(harness.stubSession.createdTasks.count == 1)
        #expect(harness.stubTask.resumeCount == 1)
        await harness.manager.cancel(task)
        await harness.manager.shutdown()
    }

    @Test("query, fragment, remote host, root, and directory-shaped URLs fail closed")
    func unsafeURLShapesFailClosed() throws {
        let rootURL = makeTemporaryRoot(label: "unsafe-shapes")
        let unsafeURLs = [
            URL(string: "file:///tmp/output.bin?version=1")!,
            URL(string: "file:///tmp/output.bin#fragment")!,
            URL(string: "file://files.example.invalid/share/output.bin")!,
            URL(fileURLWithPath: "/", isDirectory: false),
            URL(fileURLWithPath: rootURL.appendingPathComponent("folder").path, isDirectory: true),
        ]

        for url in unsafeURLs {
            #expect(throws: DownloadDestinationPreflightFailure.self) {
                try DownloadDestinationPreflight.validate(url)
            }
        }
    }

    private func expectPreflightFailure(
        _ task: DownloadTask,
        harness: StubDownloadHarness
    ) async {
        #expect(await task.state == .failed)
        guard case .fileSystemError(let underlying)? = await task.error else {
            Issue.record("Expected destination preflight fileSystemError")
            return
        }
        #expect(underlying.domain == DownloadDestinationPreflight.errorDomain)
        #expect(harness.stubSession.createdTasks.isEmpty)
        #expect(harness.stubTask.resumeCount == 0)
        #expect(harness.stubTask.taskDescription == nil)
    }

    private func makeTemporaryRoot(label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDestinationPreflight-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
