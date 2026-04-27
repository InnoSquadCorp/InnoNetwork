import Foundation
import InnoNetwork
import InnoNetworkDownload


// MARK: - CLI argument / env parsing

/// Default test asset. Public HTTPS fixture verified on 2026-04-21;
/// override via CLI arg if unavailable.
private let defaultURLString = "https://proof.ovh.net/files/1Mb.dat"

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment
let runIntegration = environment["INNONETWORK_RUN_INTEGRATION"] == "1"

let rawURLString: String = arguments.count > 1 ? arguments[1] : defaultURLString

let destinationURL: URL = {
    if arguments.count > 2 {
        return URL(fileURLWithPath: arguments[2])
    }
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("InnoNetworkDownloadSample", isDirectory: true)
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    return temp.appendingPathComponent("sample-\(UUID().uuidString).bin")
}()

guard
    let url = URL(string: rawURLString),
    let scheme = url.scheme?.lowercased(),
    scheme == "http" || scheme == "https"
else {
    FileHandle.standardError.write(Data("Usage: DownloadManagerSample [https://host/path] [destination.bin]\n".utf8))
    exit(2)
}


// MARK: - Guarded entry point

guard runIntegration else {
    let note = """
    DownloadManagerSample
    ---------------------
    Source URL        : \(url.absoluteString)
    Destination       : \(destinationURL.path)
    Exponential backoff: enabled (retryDelay=1s, maxRetryDelay=60s)

    Set INNONETWORK_RUN_INTEGRATION=1 to actually download. Example:

        INNONETWORK_RUN_INTEGRATION=1 swift run DownloadManagerSample
        INNONETWORK_RUN_INTEGRATION=1 swift run DownloadManagerSample \\
            https://example.com/file.zip /tmp/out.zip

    Leaving the env var unset is expected in CI — the sample exits 0 here.

    """
    FileHandle.standardOutput.write(Data(note.utf8))
    exit(0)
}


// MARK: - Live download

// Showcases future-candidate exponential backoff tuning alongside the existing
// event-stream consumption pattern.
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.innonetwork.sample.download.\(UUID().uuidString)"
) {
    $0.maxRetryCount = 3
    $0.maxTotalRetries = 5
    $0.retryDelay = 1.0
    $0.exponentialBackoff = true
    $0.retryJitterRatio = 0.2
    $0.maxRetryDelay = 60
}

let manager: DownloadManager
do {
    manager = try DownloadManager(configuration: configuration)
} catch {
    FileHandle.standardError.write(Data("Failed to build DownloadManager: \(error)\n".utf8))
    exit(1)
}

let task = await manager.download(url: url, to: destinationURL)
print("▶︎ started  \(url.absoluteString)")
print("            → \(destinationURL.path)")

var lastReportedPercent = -1
for await event in await manager.events(for: task) {
    switch event {
    case .progress(let progress):
        // Keep log volume reasonable for CLI — only reprint when the
        // integer percentage changes.
        let percent = progress.percentCompleted
        if percent != lastReportedPercent {
            lastReportedPercent = percent
            print(String(
                format: "   %3d%%  (%lld / %lld bytes)",
                percent,
                progress.totalBytesWritten,
                progress.totalBytesExpectedToWrite
            ))
        }
    case .stateChanged(let state):
        print("   state → \(state)")
    case .completed(let fileURL):
        print("✓ completed at \(fileURL.path)")
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? -1
        print("   size on disk: \(size) bytes")
        exit(0)
    case .failed(let error):
        FileHandle.standardError.write(Data("✗ failed: \(error)\n".utf8))
        exit(1)
    @unknown default:
        break
    }
}

FileHandle.standardError.write(
    Data("✗ download event stream closed unexpectedly before completion\n".utf8)
)
exit(1)
