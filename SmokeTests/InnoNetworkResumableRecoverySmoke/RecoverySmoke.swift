// Avoid main.swift's implicit entry point when Xcode 26 builds this @main target.
import Darwin
import Foundation
import InnoNetworkUpload

private enum FixtureError: Error {
    case invalidArguments
    case contractViolation(String)
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw FixtureError.contractViolation(message) }
}

/// A deterministic durable backend stand-in, not an HTTP server or a cloud
/// service. Only non-secret session identity and accepted bytes survive exit.
private struct ServerState: Codable {
    var bytes = Data()
    var ranges: [String] = []
    var createCount = 0
    var finalizeCount = 0
}

private actor DurableFixtureAdapter: ResumableUploadAdapting {
    let stateURL: URL
    let phase: String
    var state: ServerState

    init(directory: URL, phase: String) throws {
        stateURL = directory.appendingPathComponent("server.json")
        self.phase = phase
        state = try JSONDecoder().decode(ServerState.self, from: Data(contentsOf: stateURL))
    }

    private func authenticate(_ request: URLRequest) throws {
        try require(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-\(phase)", "fresh credentials")
    }

    private func save() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    func createSession(request: URLRequest, fileSize: Int64, fileSHA256: String) async throws -> String {
        try authenticate(request)
        state.createCount += 1
        try save()
        return "non-secret-session"
    }

    func probe(sessionIdentifier: String, request: URLRequest, fileSize: Int64) async throws -> Int64 {
        try authenticate(request)
        try require(sessionIdentifier == "non-secret-session", "session identity")
        return Int64(state.bytes.count)
    }

    func uploadChunk(
        _ data: Data,
        range: Range<Int64>,
        fileSize: Int64,
        sessionIdentifier: String,
        request: URLRequest
    ) async throws -> Int64 {
        try authenticate(request)
        try require(range.lowerBound == Int64(state.bytes.count), "no repeated or skipped bytes")
        try require(Int64(data.count) == range.count, "chunk length")
        state.bytes.append(data)
        state.ranges.append("\(range.lowerBound)..<\(range.upperBound)")
        try save()
        if phase == "interrupt-chunk", state.bytes.count == 8 {
            // Exit our fixture process only, after durable server acceptance
            // but before the caller can persist the acknowledgement.
            _exit(86)
        }
        return Int64(state.bytes.count)
    }

    func finalize(
        sessionIdentifier: String,
        request: URLRequest,
        fileSize: Int64,
        fileSHA256: String
    ) async throws {
        try authenticate(request)
        try require(state.bytes == Data("abcdefghij".utf8), "exact final bytes")
        state.finalizeCount += 1
        try save()
        if phase == "interrupt-finalize" {
            // Models acknowledgement loss after an idempotent server finalize.
            _exit(87)
        }
    }
}

@main
private enum RecoverySmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw FixtureError.invalidArguments }
        let phase = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        if phase == "ownership" || phase == "hold-owner" {
            try await ResumableOwnershipSmoke.run(phase: phase, directory: directory)
            return
        }
        let payload = directory.appendingPathComponent("payload.bin")
        let serverURL = directory.appendingPathComponent("server.json")
        if phase == "prepare" {
            try require(!FileManager.default.fileExists(atPath: serverURL.path), "fresh fixture directory")
            try Data("abcdefghij".utf8).write(to: payload, options: .atomic)
            try JSONEncoder().encode(ServerState()).write(to: serverURL, options: .atomic)
            return
        }
        let allowedPhases = ["interrupt-chunk", "interrupt-finalize", "resume-chunk", "resume-finalize"]
        try require(allowedPhases.contains(phase), "known phase")
        let checkpointDirectory = directory.appendingPathComponent("checkpoints", isDirectory: true)
        let store = try FileResumableUploadCheckpointStore(directory: checkpointDirectory)
        if phase.hasPrefix("resume-") {
            let orphanDirectory = directory.appendingPathComponent("snapshots/innonetwork-resumable-v1")
            try require(
                try FileManager.default.contentsOfDirectory(atPath: orphanDirectory.path).count == 1,
                "crashed process leaves exactly one recoverable orphan")
            let checkpoint = try await store.load(uploadID: "fixture-job")
            try require(
                checkpoint?.confirmedOffset == (phase == "resume-chunk" ? 4 : 10), "last acknowledged checkpoint")
            let files = try FileManager.default.contentsOfDirectory(
                at: checkpointDirectory, includingPropertiesForKeys: nil
            )
            let checkpoints = files.filter { $0.pathExtension == "json" }
            let locks = files.filter { $0.pathExtension == "upload-lock" }
            try require(
                checkpoints.count == 1 && locks.count == 1 && files.count == 2, "checkpoint and crashed-owner lock")
            try require(try Data(contentsOf: locks[0]).isEmpty, "lock contains no payload or credentials")
            let persisted = try String(contentsOf: checkpoints[0], encoding: .utf8)
            try require(
                !persisted.contains("Bearer") && !persisted.contains("Authorization"), "credential-free checkpoint")
        }
        let adapter = try DurableFixtureAdapter(directory: directory, phase: phase)
        let engine = try ResumableUploadEngine(
            chunkSize: 4,
            adapter: adapter,
            checkpointStore: store,
            snapshotDirectory: directory.appendingPathComponent("snapshots", isDirectory: true)
        )
        guard let destination = URL(string: "https://upload.example.test/files") else {
            throw FixtureError.invalidArguments
        }
        var request = URLRequest(url: destination)
        request.setValue("Bearer fixture-\(phase)", forHTTPHeaderField: "Authorization")
        let result = try await engine.upload(id: "fixture-job", fileURL: payload, request: request)
        try require(phase.hasPrefix("resume-"), "interruption must exit before success")
        let state = try JSONDecoder().decode(ServerState.self, from: Data(contentsOf: serverURL))
        try require(state.createCount == 1, "no replacement server session")
        try require(state.finalizeCount == (phase == "resume-finalize" ? 2 : 1), "idempotent finalization")
        try require(state.ranges == ["0..<4", "4..<8", "8..<10"], "server offsets determine recovery")
        try require(result.bytesConfirmed == 10, "completed byte count")
        let checkpoint = try await store.load(uploadID: "fixture-job")
        try require(checkpoint == nil, "successful recovery removes checkpoint")
        try require(
            try FileManager.default.contentsOfDirectory(atPath: checkpointDirectory.path).isEmpty,
            "successful recovery removes its stale ownership lock")
        let snapshotDirectory = directory.appendingPathComponent("snapshots/innonetwork-resumable-v1")
        try require(
            try FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path).isEmpty,
            "fresh process reclaims orphan and completed snapshot")
        print("resumable recovery \(phase): PASS")
    }
}
