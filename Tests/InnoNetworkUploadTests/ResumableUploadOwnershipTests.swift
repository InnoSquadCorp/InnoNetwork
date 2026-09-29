import Foundation
import Testing

@testable import InnoNetworkUpload

@Suite("Resumable upload ownership", .timeLimit(.minutes(1)))
struct ResumableUploadOwnershipTests {
    @Test(
        arguments: ["copy", "anotherEngine", "anotherStore", "directoryAlias", "customStore"], ["create", "chunk"]
    )
    func duplicateCannotRemoveLiveCheckpoint(variant: String, phase: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data("abcd".utf8).write(to: file)
        let checkpointDirectory = root.appendingPathComponent("checkpoints")
        let store: any ResumableUploadCheckpointStoring =
            variant == "customStore"
            ? MemoryStore() : try FileResumableUploadCheckpointStore(directory: checkpointDirectory)
        let adapter = Adapter(phase: phase)
        let engine = try ResumableUploadEngine(chunkSize: 2, adapter: adapter, checkpointStore: store)
        let second: ResumableUploadEngine
        switch variant {
        case "anotherEngine":
            second = try ResumableUploadEngine(chunkSize: 2, adapter: adapter, checkpointStore: store)
        case "anotherStore", "directoryAlias":
            var directory = checkpointDirectory
            if variant == "directoryAlias" {
                directory = root.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: checkpointDirectory)
            }
            second = try ResumableUploadEngine(
                chunkSize: 2, adapter: adapter,
                checkpointStore: FileResumableUploadCheckpointStore(directory: directory))
        default: second = engine
        }
        var heldRequest = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        heldRequest.setValue("held", forHTTPHeaderField: "Role")
        let request = heldRequest
        let task = Task {
            defer { adapter.entryContinuation.finish() }
            return try await engine.upload(id: "job", fileURL: file, request: request)
        }
        await withTaskCancellationHandler {
            var entries = adapter.entered.makeAsyncIterator()
            let entered: Void? = await entries.next()
            #expect(entered != nil)
            if entered != nil {
                let before = try? await store.load(uploadID: "job")
                #expect(before?.confirmedOffset == (phase == "create" ? nil : 2))
                let creations = await adapter.creations
                let other = URLRequest(url: URL(string: "https://upload.example.test/files")!)
                await #expect(throws: ResumableUploadError.uploadAlreadyInProgress) {
                    try await second.upload(id: "job", fileURL: file, request: other)
                }
                #expect((try? await store.load(uploadID: "job")) == before)
                #expect(await adapter.creations == creations)
                // Distinct IDs can finish while the original remains held.
                let control = try? await second.upload(id: "different", fileURL: file, request: other)
                #expect(control?.bytesConfirmed == 4)
                #expect((try? await store.load(uploadID: "job")) == before)
            }
            task.cancel()
            _ = await task.result
        } onCancel: {
            task.cancel()
            adapter.entryContinuation.finish()
        }
        #expect(try await store.load(uploadID: "job")?.confirmedOffset == (phase == "create" ? nil : 2))
        // Cancellation releases ownership; a retry probes the saved session.
        let result = try await second.upload(
            id: "job", fileURL: file, request: URLRequest(url: URL(string: "https://upload.example.test/files")!))
        #expect(result.bytesConfirmed == 4)
        #expect(try await store.load(uploadID: "job") == nil)
        if variant != "customStore" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: checkpointDirectory.path).isEmpty)
        }
    }

    @Test func snapshotFailureReleasesOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try FileResumableUploadCheckpointStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ResumableUploadEngine(adapter: Adapter(phase: "none"), checkpointStore: store)
        let missing = root.appendingPathComponent("missing")
        let request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        for _ in 0..<2 {
            await #expect(throws: ResumableUploadError.unreadableFile) {
                try await engine.upload(id: "job", fileURL: missing, request: request)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func leaseRejectsForeignEntriesAndReleasesIdempotently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign")
        try Data("preserve".utf8).write(to: foreign)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        #expect(throws: (any Error).self) { try ResumableUploadFileLease(directory: root, name: "alias") }
        #expect(try Data(contentsOf: foreign) == Data("preserve".utf8))
        let lease = try ResumableUploadFileLease(directory: root, name: "owned")
        #expect(throws: ResumableUploadError.uploadAlreadyInProgress) {
            try ResumableUploadFileLease(directory: root, name: "owned")
        }
        lease.release()
        let next = try ResumableUploadFileLease(directory: root, name: "owned")
        lease.release()  // Cannot close or unlink the replacement owner's lease.
        #expect(throws: ResumableUploadError.uploadAlreadyInProgress) {
            try ResumableUploadFileLease(directory: root, name: "owned")
        }
        next.release()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("owned").path))
    }

    private actor MemoryStore: ResumableUploadCheckpointStoring {
        var values: [String: ResumableUploadCheckpoint] = [:]
        func load(uploadID: String) async throws -> ResumableUploadCheckpoint? { values[uploadID] }
        func save(_ checkpoint: ResumableUploadCheckpoint) async throws { values[checkpoint.uploadID] = checkpoint }
        func remove(uploadID: String) async throws { values[uploadID] = nil }
    }

    private actor Adapter: ResumableUploadAdapting {
        nonisolated let entered: AsyncStream<Void>
        nonisolated let entryContinuation: AsyncStream<Void>.Continuation
        let phase: String
        private(set) var creations = 0
        init(phase: String) {
            self.phase = phase
            (entered, entryContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }
        func createSession(request: URLRequest, fileSize: Int64, fileSHA256: String) async throws -> String {
            creations += 1
            if phase == "create", request.value(forHTTPHeaderField: "Role") == "held" { try await hold() }
            return "session"
        }
        func probe(sessionIdentifier: String, request: URLRequest, fileSize: Int64) async throws -> Int64 { 0 }
        func uploadChunk(
            _ data: Data, range: Range<Int64>, fileSize: Int64, sessionIdentifier: String, request: URLRequest
        ) async throws -> Int64 {
            if phase == "chunk", request.value(forHTTPHeaderField: "Role") == "held", range.lowerBound == 2 {
                try await hold()
            }
            try Task.checkCancellation()
            return range.upperBound
        }
        private func hold() async throws {
            entryContinuation.yield(())
            // This delay models a pending transport, not test synchronization.
            try await Task.sleep(for: .seconds(3600))
        }
        func finalize(sessionIdentifier: String, request: URLRequest, fileSize: Int64, fileSHA256: String) async throws
        {}
    }
}
