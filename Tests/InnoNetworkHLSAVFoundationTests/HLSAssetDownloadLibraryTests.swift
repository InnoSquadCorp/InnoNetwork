#if canImport(AVFoundation) && !os(tvOS) && !os(watchOS)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS offline library", .serialized)
struct HLSAssetDownloadLibraryTests {
    @Test("library preserves order and replaces an identifier in place")
    func registrationOrderAndReplacement() throws {
        let first = try storedAsset(id: "first", suffix: "first")
        let second = try storedAsset(id: "second", suffix: "second")
        let replacement = try storedAsset(
            id: "first",
            suffix: "replacement"
        )

        let library = try HLSAssetDownloadLibrary()
            .registering(first)
            .registering(second)
            .registering(replacement)

        #expect(library.assets == [replacement, second])
        #expect(library.asset(id: "first") == replacement)
        #expect(library.asset(id: "missing") == nil)
        #expect(
            library.removingReference(id: "first").assets
                == [second]
        )
    }

    @Test("library round-trips and rejects duplicate identifiers")
    func codingAndIdentityValidation() throws {
        let first = try storedAsset(id: "first", suffix: "first")
        let second = try storedAsset(id: "second", suffix: "second")
        let library = try HLSAssetDownloadLibrary(
            assets: [first, second]
        )

        let encoded = try JSONEncoder().encode(library)
        #expect(
            String(decoding: encoded, as: UTF8.self)
                .contains("\"schemaVersion\":1")
        )
        #expect(
            try JSONDecoder().decode(
                HLSAssetDownloadLibrary.self,
                from: encoded
            ) == library
        )
        #expect(
            throws:
                HLSAssetDownloadLibraryError
                .duplicateAssetIdentifier("first")
        ) {
            try HLSAssetDownloadLibrary(
                assets: [first, first]
            )
        }
        #expect(
            throws:
                HLSAssetDownloadLibraryError
                .duplicateAssetIdentifier("first")
        ) {
            try JSONDecoder().decode(
                HLSAssetDownloadLibrary.self,
                from: Data(
                    """
                    {
                      "schemaVersion": 1,
                      "assets": [
                        {
                          "id": "first",
                          "location": "file:///tmp/first.movpkg"
                        },
                        {
                          "id": "first",
                          "location": "file:///tmp/second.movpkg"
                        }
                      ]
                    }
                    """.utf8
                )
            )
        }
        #expect(
            throws:
                HLSAssetDownloadLibraryError
                .unsupportedSchemaVersion(2)
        ) {
            try JSONDecoder().decode(
                HLSAssetDownloadLibrary.self,
                from: Data(
                    """
                    {
                      "schemaVersion": 2,
                      "assets": []
                    }
                    """.utf8
                )
            )
        }
        #expect(
            throws:
                HLSAssetDownloadLibraryError
                .duplicateAssetLocation(first.location)
        ) {
            try HLSAssetDownloadLibrary(
                assets: [
                    first,
                    try HLSStoredAsset(
                        id: "another-id",
                        location: first.location
                    ),
                ]
            )
        }
    }

    @Test("inspection and pruning retain only available packages")
    func inspectionAndPruning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetworkHLSLibraryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let availableURL = root.appendingPathComponent(
            "available.movpkg",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: availableURL,
            withIntermediateDirectories: false
        )
        let available = try HLSStoredAsset(
            id: "available",
            location: availableURL
        )
        let missing = try HLSStoredAsset(
            id: "missing",
            location: root.appendingPathComponent(
                "missing.movpkg",
                isDirectory: true
            )
        )
        let library = try HLSAssetDownloadLibrary(
            assets: [available, missing]
        )
        let storage = HLSAssetDownloadStorage()

        let inspection = try await storage.inspect(library)
        #expect(inspection.map(\.asset) == [available, missing])
        #expect(
            inspection.map(\.availability)
                == [.available, .missing]
        )

        let pruned = try await library.pruningMissingAssets(
            using: storage
        )
        #expect(pruned.assets == [available])
    }

    @Test("library failures have actionable diagnostics")
    func diagnostics() {
        let error =
            HLSAssetDownloadLibraryError
            .duplicateAssetIdentifier("episode")
        #expect(!error.localizedDescription.isEmpty)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }

    private func storedAsset(
        id: String,
        suffix: String
    ) throws -> HLSStoredAsset {
        try HLSStoredAsset(
            id: id,
            location: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(suffix).movpkg")
        )
    }
}
#endif
