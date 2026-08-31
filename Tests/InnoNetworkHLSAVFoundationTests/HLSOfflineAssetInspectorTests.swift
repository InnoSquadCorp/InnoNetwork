#if canImport(AVFoundation) && !os(tvOS) && !os(watchOS)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS offline readiness", .serialized)
struct HLSOfflineAssetInspectorTests {
    @Test("missing, invalid, and incomplete packages stay distinct")
    func packageStatesRemainDistinct() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let inspector = HLSOfflineAssetInspector()

        let missing = try HLSStoredAsset(
            id: "missing",
            location: root.appendingPathComponent("missing.movpkg")
        )
        let missingSnapshot = try await inspector.inspect(missing)
        #expect(missingSnapshot.state == .missing)
        #expect(!missingSnapshot.isPlayableOffline)
        #expect(missingSnapshot.mediaSelectionGroups.isEmpty)
        #expect(!missingSnapshot.didCompleteMediaSelectionInspection)

        let invalidURL = root.appendingPathComponent("invalid.movpkg")
        try Data("not a package".utf8).write(to: invalidURL)
        let invalid = try HLSStoredAsset(
            id: "invalid",
            location: invalidURL
        )
        #expect(
            try await inspector.inspect(invalid).state == .invalidPackage
        )

        let incompleteURL = root.appendingPathComponent(
            "incomplete.movpkg",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: incompleteURL,
            withIntermediateDirectories: false
        )
        let incomplete = try HLSStoredAsset(
            id: "incomplete",
            location: incompleteURL
        )
        let incompleteSnapshot = try await inspector.inspect(incomplete)
        #expect(incompleteSnapshot.state == .incomplete)
        #expect(!incompleteSnapshot.isPlayableOffline)
    }

    @Test("inspection preserves structured cancellation")
    func inspectionPreservesCancellation() async throws {
        let asset = try HLSStoredAsset(
            id: "cancelled",
            location: FileManager.default.temporaryDirectory
                .appendingPathComponent("cancelled.movpkg")
        )
        let inspector = HLSOfflineAssetInspector()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await inspector.inspect(asset)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("language metadata is bounded, safe, unique, and ordered")
    func languageMetadataIsBounded() {
        #expect(
            HLSOfflineAssetMapper.boundedLanguageTag(" ko ") == "ko"
        )
        #expect(
            HLSOfflineAssetMapper.boundedLanguageTag("ko\nKR") == nil
        )
        #expect(
            HLSOfflineAssetMapper.boundedLanguageTag(
                String(repeating: "a", count: 129)
            ) == nil
        )
        #expect(
            HLSOfflineAssetMapper.boundedLanguageTag(
                String(repeating: " ", count: 128) + "a"
            ) == nil
        )

        let native =
            ["ko", "KO", "en"]
            + (0..<260).map { "language-\($0)" }
        let bounded = HLSOfflineAssetMapper.boundedLanguageTags(native)

        #expect(bounded.values.prefix(2) == ["ko", "en"])
        #expect(
            bounded.values.count
                == HLSOfflineAssetMapper.maximumCustomLanguageCount
        )
        #expect(bounded.wasTruncated)

        let coverage = HLSOfflineAssetMapper.boundedLanguageSet(
            [" ko ", "KO", "en\u{0000}"]
        )
        #expect(coverage.values == ["ko"])
        #expect(coverage.didOmitValue)
    }

    @Test("custom media coverage distinguishes none, partial, and complete")
    func customMediaCoverageIsTyped() {
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: 0,
                cachedLanguageCount: 0,
                authoredSettingCount: 0,
                cachedSettingCount: 0
            ) == .complete
        )
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: 2,
                cachedLanguageCount: 0,
                authoredSettingCount: 2,
                cachedSettingCount: 0
            ) == .none
        )
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: 2,
                cachedLanguageCount: 1,
                authoredSettingCount: 2,
                cachedSettingCount: 1
            ) == .partial
        )
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: 2,
                cachedLanguageCount: 2,
                authoredSettingCount: 2,
                cachedSettingCount: 2
            ) == .complete
        )
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: 1,
                cachedLanguageCount: 100,
                authoredSettingCount: 1,
                cachedSettingCount: 100
            ) == .complete
        )
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: 1,
                cachedLanguageCount: 100,
                authoredSettingCount: 1,
                cachedSettingCount: 0
            ) == .partial
        )
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: .max,
                cachedLanguageCount: .max,
                authoredSettingCount: .max,
                cachedSettingCount: .max
            ) == .complete
        )
        #expect(
            HLSOfflineAssetMapper.customCoverage(
                authoredLanguageCount: 1,
                cachedLanguageCount: 1,
                authoredSettingCount: 1,
                cachedSettingCount: 1,
                didTruncateInspection: true
            ) == .indeterminate
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetworkHLSReadinessTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
#endif
