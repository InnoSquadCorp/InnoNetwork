#if canImport(AVFoundation) && !os(tvOS) && !os(watchOS)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS storage", .serialized)
struct HLSAssetDownloadStorageTests {
    @Test("stored references validate and round-trip")
    func storedReferenceRoundTrip() throws {
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("episode.movpkg")
        let asset = try HLSStoredAsset(
            id: "episode-1",
            location: location
        )

        let encoded = try JSONEncoder().encode(asset)
        #expect(try JSONDecoder().decode(HLSStoredAsset.self, from: encoded) == asset)
        #expect(
            throws:
                HLSAssetDownloadStorageError
                .invalidAssetIdentifier
        ) {
            try HLSStoredAsset(id: " ", location: location)
        }
        #expect(throws: HLSAssetDownloadStorageError.invalidAssetURL) {
            try HLSStoredAsset(
                id: "episode-1",
                location: #require(
                    URL(string: "https://media.example/episode.movpkg")
                )
            )
        }
        #expect(throws: HLSAssetDownloadStorageError.invalidAssetURL) {
            try HLSStoredAsset(
                id: "episode-1",
                location: location.deletingPathExtension()
            )
        }
        #expect(throws: HLSAssetDownloadStorageError.invalidAssetURL) {
            try JSONDecoder().decode(
                HLSStoredAsset.self,
                from: Data(
                    """
                    {
                      "id": "episode-1",
                      "location": "https://media.example/episode.movpkg"
                    }
                    """.utf8
                )
            )
        }
    }

    @Test("download handles bind delivered package locations")
    func downloadBindsStoredAsset() throws {
        let download = HLSAssetDownload(
            id: "episode-2",
            taskIdentifier: 2,
            sessionIdentifier: "com.example.session"
        )
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("episode.movpkg")

        let asset = try download.storedAsset(at: location)

        #expect(asset.id == download.id)
        #expect(asset.location == location.standardizedFileURL)
    }

    @Test("storage reports and removes packages idempotently")
    func storageLifecycle() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let packageURL = directoryURL.appendingPathComponent(
            "episode.movpkg",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        let asset = try HLSStoredAsset(
            id: "episode-3",
            location: packageURL
        )
        let storage = HLSAssetDownloadStorage()
        let policy = HLSAssetDownloadStoragePolicy(
            expirationDate: Date().addingTimeInterval(86_400),
            evictionPriority: .important
        )

        #expect(try await storage.availability(of: asset) == .available)
        await #expect(
            throws:
                HLSAssetDownloadStorageError
                .storagePolicyUnavailable
        ) {
            try await storage.setPolicy(policy, for: asset)
        }
        #expect(try await storage.remove(asset))
        #expect(try await storage.availability(of: asset) == .missing)
        #expect(try await !storage.remove(asset))
        await #expect(
            throws: HLSAssetDownloadStorageError.assetNotFound
        ) {
            try await storage.setPolicy(policy, for: asset)
        }
    }

    @Test("storage never follows a package symlink")
    func rejectsPackageSymlink() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let targetURL = directoryURL.appendingPathComponent(
            "target",
            isDirectory: true
        )
        let linkURL = directoryURL.appendingPathComponent(
            "linked.movpkg",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let asset = try HLSStoredAsset(
            id: "episode-4",
            location: linkURL
        )
        let storage = HLSAssetDownloadStorage()

        await #expect(
            throws: HLSAssetDownloadStorageError.invalidAssetPackage
        ) {
            try await storage.remove(asset)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: targetURL.path
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetworkHLSStorageTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }
}
#endif
