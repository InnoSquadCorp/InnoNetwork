import Foundation
import InnoNetwork
import InnoNetworkDownload


// MARK: - InnoNetworkDownloadSmoke
//
// Integration smoke that exercises the real URLSession-backed
// `DownloadManager.pause/resume` path end-to-end. This is intentionally
// gated behind `INNONETWORK_RUN_INTEGRATION=1` so offline CI runs of
// `swift build` stay unaffected.
//
// Scenario:
//   1. Kick off a medium-sized public download.
//   2. Wait for the first `.progress` event, then pause after ~100 ms.
//   3. Verify `task.resumeData` is non-nil after pause.
//   4. Resume, wait for `.completed(URL)`.
//   5. Verify the destination file exists with a non-zero size.
//   6. Clean up the temporary file.
//
// Exit code 0 on success, 1 on failure, 0 when skipped (no env flag).

private let environment = ProcessInfo.processInfo.environment
private let runIntegration = environment["INNONETWORK_RUN_INTEGRATION"] == "1"
private let arguments = CommandLine.arguments
private let urlString: String? = arguments.count > 1 ? arguments[1] : nil

private let destinationURL: URL = {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("InnoNetworkDownloadSmoke", isDirectory: true)
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    return temp.appendingPathComponent("smoke-\(UUID().uuidString).bin")
}()


// MARK: - Guarded entry point

guard runIntegration else {
    let note = """
    InnoNetworkDownloadSmoke skipped (INNONETWORK_RUN_INTEGRATION != 1).
    Set the flag and provide an explicit HTTPS URL to exercise the
    pause/resume path:

        INNONETWORK_RUN_INTEGRATION=1 swift run InnoNetworkDownloadSmoke \\
            https://example.com/large-file.bin

    """
    FileHandle.standardOutput.write(Data(note.utf8))
    exit(0)
}

guard let urlString else {
    FileHandle.standardError.write(
        Data(
            "Usage: INNONETWORK_RUN_INTEGRATION=1 swift run InnoNetworkDownloadSmoke [https://host/path]\n".utf8
        )
    )
    exit(2)
}

guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
    FileHandle.standardError.write(Data("Invalid HTTPS URL: \(urlString)\n".utf8))
    exit(1)
}


// MARK: - Live pause/resume smoke

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    try? FileManager.default.removeItem(at: destinationURL)
    exit(1)
}

let configuration = DownloadConfiguration.safeDefaults(
    sessionIdentifier: "com.innonetwork.smoke.download.\(UUID().uuidString)"
)

let manager: DownloadManager
do {
    manager = try DownloadManager(configuration: configuration)
} catch {
    fail("Failed to build DownloadManager: \(error)")
}

print("▶︎ download   \(url.absoluteString)")
print("            → \(destinationURL.path)")

let task = await manager.download(url: url, to: destinationURL)
let events = await manager.events(for: task)

var didPause = false
var didResume = false
var sawProgressBeforePause = false

for await event in events {
    switch event {
    case .progress(let progress):
        if !sawProgressBeforePause {
            sawProgressBeforePause = true
            print("   first progress: \(progress.totalBytesWritten) bytes — scheduling pause")
            try? await Task.sleep(nanoseconds: 100_000_000) // ~100ms
            await manager.pause(task)
        }
    case .stateChanged(let state):
        print("   state → \(state)")
        if state == .paused, !didPause {
            didPause = true
            let resumeData = await task.resumeData
            if resumeData == nil {
                fail("expected non-nil resumeData after pause")
            }
            print("   resumeData size: \(resumeData?.count ?? 0) bytes — resuming")
            await manager.resume(task)
            didResume = true
        }
    case .completed(let fileURL):
        guard didPause, didResume else {
            fail("completed before pause/resume cycle ran (pause=\(didPause) resume=\(didResume))")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int64) ?? -1
        guard size > 0 else {
            fail("completed file has non-positive size: \(size)")
        }
        print("✓ completed  \(fileURL.path) (\(size) bytes)")
        try? FileManager.default.removeItem(at: fileURL)
        print("InnoNetworkDownloadSmoke OK")
        exit(0)
    case .failed(let error):
        fail("download failed: \(error)")
    @unknown default:
        break
    }
}

fail("event stream closed before completion")
