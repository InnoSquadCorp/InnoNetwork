import Foundation
import Testing
@testable import InnoNetworkDownload


@Suite("Persistence Fsync Policy Tests")
struct PersistenceFsyncPolicyTests {

    @Test("Default DownloadConfiguration uses .onCheckpoint")
    func defaultIsOnCheckpoint() {
        let configuration = DownloadConfiguration()
        #expect(configuration.persistenceFsyncPolicy == .onCheckpoint)
    }

    @Test("Advanced builder propagates the override")
    func advancedBuilderRoundTrips() {
        let always = DownloadConfiguration.advanced(
            sessionIdentifier: "test.fsync.always.\(UUID().uuidString)"
        ) { builder in
            builder.persistenceFsyncPolicy = .always
        }
        #expect(always.persistenceFsyncPolicy == .always)

        let never = DownloadConfiguration.advanced(
            sessionIdentifier: "test.fsync.never.\(UUID().uuidString)"
        ) { builder in
            builder.persistenceFsyncPolicy = .never
        }
        #expect(never.persistenceFsyncPolicy == .never)
    }

    @Test("All three policies persist data round-trip through the actor",
          arguments: [
            DownloadConfiguration.PersistenceFsyncPolicy.always,
            .onCheckpoint,
            .never,
          ])
    func policyRoundTrip(policy: DownloadConfiguration.PersistenceFsyncPolicy) async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inno-fsync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let persistence = DownloadTaskPersistence(
            sessionIdentifier: "test.fsync.\(UUID().uuidString)",
            baseDirectoryURL: baseDirectory,
            fsyncPolicy: policy
        )

        let id = UUID().uuidString
        let url = URL(string: "https://example.invalid/file.zip")!
        let destination = baseDirectory.appendingPathComponent("file.zip")
        await persistence.upsert(id: id, url: url, destinationURL: destination)

        let record = await persistence.record(forID: id)
        #expect(record?.id == id)
        #expect(record?.url == url)
        #expect(record?.destinationURL == destination)
    }

    @Test("PersistenceFsyncPolicy is Equatable across cases")
    func equality() {
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.always == .always)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.onCheckpoint == .onCheckpoint)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.never == .never)
        #expect(DownloadConfiguration.PersistenceFsyncPolicy.always != .never)
    }
}
