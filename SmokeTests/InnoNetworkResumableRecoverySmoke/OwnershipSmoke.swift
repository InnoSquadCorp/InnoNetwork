import Darwin
import Foundation
import InnoNetworkUpload

private enum OwnershipFixtureError: Error { case violated(String) }

private actor OwnershipAdapter: ResumableUploadAdapting {
    let hold: Bool
    init(hold: Bool) { self.hold = hold }
    func createSession(request: URLRequest, fileSize: Int64, fileSHA256: String) async throws -> String { "session" }
    func probe(sessionIdentifier: String, request: URLRequest, fileSize: Int64) async throws -> Int64 {
        if hold {
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            _ = try FileHandle.standardInput.read(upToCount: 1)
            // Crash only this fixture after the parent has exercised overlap.
            _exit(88)
        }
        return 0
    }
    func uploadChunk(
        _ data: Data, range: Range<Int64>, fileSize: Int64, sessionIdentifier: String, request: URLRequest
    ) async throws -> Int64 { range.upperBound }
    func finalize(sessionIdentifier: String, request: URLRequest, fileSize: Int64, fileSHA256: String) async throws {}
}

enum ResumableOwnershipSmoke {
    static func run(phase: String, directory: URL) async throws {
        let file = directory.appendingPathComponent("payload")
        let checkpointDirectory = directory.appendingPathComponent("checkpoints")
        let store = try FileResumableUploadCheckpointStore(directory: checkpointDirectory)
        let engine = try ResumableUploadEngine(
            adapter: OwnershipAdapter(hold: phase == "hold-owner"), checkpointStore: store)
        let request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        if phase == "hold-owner" {
            _ = try await engine.upload(id: "job", fileURL: file, request: request)
            throw OwnershipFixtureError.violated("held child unexpectedly completed")
        }
        try Data("abcd".utf8).write(to: file)
        #if os(macOS)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["hold-owner", directory.path]
        let entry = Pipe()
        let release = Pipe()
        child.standardOutput = entry
        child.standardInput = release
        try child.run()
        try entry.fileHandleForWriting.close()
        try release.fileHandleForReading.close()
        defer {
            try? release.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        guard try entry.fileHandleForReading.read(upToCount: 1) == Data([1]) else {
            throw OwnershipFixtureError.violated("child did not acquire ownership")
        }
        let before = try await store.load(uploadID: "job")
        do {
            _ = try await engine.upload(id: "job", fileURL: file, request: request)
            throw OwnershipFixtureError.violated("duplicate process was admitted")
        } catch ResumableUploadError.uploadAlreadyInProgress {
            // Required rejection, not an ignored failure.
        }
        guard try await store.load(uploadID: "job") == before else {
            throw OwnershipFixtureError.violated("duplicate changed the checkpoint")
        }
        _ = try await engine.upload(id: "other-job", fileURL: file, request: request)
        try release.fileHandleForWriting.close()
        child.waitUntilExit()
        guard child.terminationStatus == 88 else { throw OwnershipFixtureError.violated("child exit") }
        // The OS releases the crashed owner's descriptor. No timeout-based
        // stealing is needed, and the next owner cleans up the inert file.
        _ = try await engine.upload(id: "job", fileURL: file, request: request)
        guard try FileManager.default.contentsOfDirectory(atPath: checkpointDirectory.path).isEmpty else {
            throw OwnershipFixtureError.violated("completed uploads left lock files")
        }
        print("resumable ownership: PASS (cross-process exclusion, distinct-ID control, crash recovery)")
        #else
        throw OwnershipFixtureError.violated("process fixture requires macOS")
        #endif
    }
}
