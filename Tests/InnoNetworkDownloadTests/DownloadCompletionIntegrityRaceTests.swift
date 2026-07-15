import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download completion integrity races")
struct DownloadCompletionIntegrityRaceTests {
    @Test("A same-size payload mutation is rejected by the persisted digest")
    func sameSizePayloadMutationIsRejected() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDownloadDigestRace-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectoryURL = rootURL.appendingPathComponent("URLSession", isDirectory: true)
        let stagingDirectoryURL = rootURL.appendingPathComponent("Staging", isDirectory: true)
        let sourceURL = sourceDirectoryURL.appendingPathComponent("download.tmp")
        let originalPayload = Data("original-payload".utf8)
        let mutatedPayload = Data("tampered-payload".utf8)
        #expect(originalPayload.count == mutatedPayload.count)

        try fileManager.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        try originalPayload.write(to: sourceURL)
        defer { try? fileManager.removeItem(at: rootURL) }

        let stager = DownloadCompletionStager(directoryURL: stagingDirectoryURL)
        let completion = try stager.stage(
            sourceURL,
            taskID: "same-size-tamper-\(UUID().uuidString)",
            originalRequestURL: URL(string: "https://example.invalid/original.bin")!,
            currentRequestURL: URL(string: "https://cdn.example.invalid/current.bin")!
        )
        let originalDigest = try stager.payloadSHA256(for: completion)

        try mutatedPayload.write(to: completion.payloadURL)

        #expect(try Data(contentsOf: completion.payloadURL).count == originalPayload.count)
        #expect(throws: DownloadCompletionStagingError.invalidManifest(completion.payloadURL.lastPathComponent)) {
            try stager.validateCommittedFile(
                at: completion.payloadURL,
                expectedByteCount: Int64(originalPayload.count),
                payloadSHA256: originalDigest
            )
        }
    }

    @Test("beginCommit rejects destination metadata that differs from the durable record")
    func destinationMetadataMismatchIsRejected() async throws {
        let fileManager = FileManager.default
        let baseDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "InnoNetworkDownloadDestinationCAS-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: baseDirectoryURL) }

        let taskID = "destination-cas-\(UUID().uuidString)"
        let sourceURL = URL(string: "https://example.invalid/source.bin")!
        let destinationURL = baseDirectoryURL.appendingPathComponent("expected.bin")
        let persistence = DownloadTaskPersistence(
            sessionIdentifier: "destination-cas-\(UUID().uuidString)",
            baseDirectoryURL: baseDirectoryURL
        )
        try await persistence.upsert(
            id: taskID,
            url: sourceURL,
            destinationURL: destinationURL
        )

        let stagingKey = try DownloadCompletionStager.stagingKey(forTaskID: taskID)
        let payloadDigest = try DownloadCompletionStager.stagingKey(forTaskID: "payload-\(taskID)")
        let mismatchedMetadata = DownloadTaskPersistence.CommitMetadata(
            stagingKey: stagingKey,
            originalRequestURL: sourceURL,
            currentRequestURL: URL(string: "https://cdn.example.invalid/source.bin")!,
            destinationURL: baseDirectoryURL.appendingPathComponent("other.bin"),
            expectedByteCount: 42,
            payloadSHA256: payloadDigest
        )

        #expect(try await persistence.beginCommit(id: taskID, metadata: mismatchedMetadata) == false)
        #expect(await persistence.record(forID: taskID)?.lifecycle == .active)

        let exactMetadata = DownloadTaskPersistence.CommitMetadata(
            stagingKey: stagingKey,
            originalRequestURL: sourceURL,
            currentRequestURL: mismatchedMetadata.currentRequestURL,
            destinationURL: destinationURL,
            expectedByteCount: mismatchedMetadata.expectedByteCount,
            payloadSHA256: payloadDigest
        )
        #expect(try await persistence.beginCommit(id: taskID, metadata: exactMetadata))
        #expect(await persistence.record(forID: taskID)?.commitMetadata == exactMetadata)
    }
}
