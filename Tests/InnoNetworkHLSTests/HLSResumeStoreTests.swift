import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS resume checkpoints")
struct HLSResumeStoreTests {
    @Test("restore truncates output to the last durable resource boundary")
    func restoreTruncatesUncheckpointedBytes() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent("video.ts")
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let resources = try [
            "first.ts",
            "second.ts",
        ].map { name in
            HLSResourceTransfer(
                url: try #require(
                    URL(string: "https://media.example/\(name)")
                ),
                byteRange: nil
            )
        }
        let store = HLSResumeStore(destinationURL: destinationURL)
        let identity = makeIdentity(
            sourceURL: sourceURL,
            playlist: "#EXTM3U\n#EXT-X-ENDLIST\n"
        )
        let initial = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: identity,
            resources: resources,
            maximumTotalBytes: 100
        )
        try Data("FIRST".utf8).write(to: initial.partialURL)
        try store.save(
            resourceCount: resources.count,
            nextResourceIndex: 1,
            assembledByteCount: 5
        )
        let handle = try FileHandle(forWritingTo: initial.partialURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("UNCOMMITTED".utf8))
        try handle.close()

        let restored = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: identity,
            resources: resources,
            maximumTotalBytes: 100
        )

        #expect(restored.nextResourceIndex == 1)
        #expect(restored.assembledByteCount == 5)
        #expect(try Data(contentsOf: restored.partialURL) == Data("FIRST".utf8))
    }

    @Test("a changed resource plan starts a clean workspace")
    func changedPlanStartsCleanWorkspace() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent("video.ts")
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let firstResource = HLSResourceTransfer(
            url: try #require(
                URL(string: "https://media.example/first.ts")
            ),
            byteRange: nil
        )
        let changedResource = HLSResourceTransfer(
            url: try #require(
                URL(string: "https://media.example/changed.ts")
            ),
            byteRange: nil
        )
        let store = HLSResumeStore(destinationURL: destinationURL)
        let identity = makeIdentity(
            sourceURL: sourceURL,
            playlist: "#EXTM3U\n#EXT-X-ENDLIST\n"
        )
        let initial = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: identity,
            resources: [firstResource],
            maximumTotalBytes: 100
        )
        try Data("STALE".utf8).write(to: initial.partialURL)
        try store.save(
            resourceCount: 1,
            nextResourceIndex: 1,
            assembledByteCount: 5
        )

        let restarted = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: identity,
            resources: [changedResource],
            maximumTotalBytes: 100
        )

        #expect(restarted.nextResourceIndex == 0)
        #expect(restarted.assembledByteCount == 0)
        #expect(try Data(contentsOf: restarted.partialURL).isEmpty)
    }

    @Test("a changed media playlist identity starts a clean workspace")
    func changedPlaylistIdentityStartsCleanWorkspace() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent("video.ts")
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let resource = HLSResourceTransfer(
            url: try #require(
                URL(string: "https://media.example/segment.ts")
            ),
            byteRange: nil
        )
        let store = HLSResumeStore(destinationURL: destinationURL)
        let initial = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: makeIdentity(
                sourceURL: sourceURL,
                playlist: "#EXTM3U\n# version one\n#EXT-X-ENDLIST\n",
                entityTag: "\"version-one\""
            ),
            resources: [resource],
            maximumTotalBytes: 100
        )
        try Data("STALE".utf8).write(to: initial.partialURL)
        try store.save(
            resourceCount: 1,
            nextResourceIndex: 1,
            assembledByteCount: 5
        )

        let restarted = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: makeIdentity(
                sourceURL: sourceURL,
                playlist: "#EXTM3U\n# version two\n#EXT-X-ENDLIST\n",
                entityTag: "\"version-two\""
            ),
            resources: [resource],
            maximumTotalBytes: 100
        )

        #expect(restarted.nextResourceIndex == 0)
        #expect(restarted.assembledByteCount == 0)
        #expect(try Data(contentsOf: restarted.partialURL).isEmpty)
    }

    @Test("a changed HTTP validator invalidates otherwise identical content")
    func changedValidatorStartsCleanWorkspace() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent("video.ts")
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let resource = HLSResourceTransfer(
            url: try #require(
                URL(string: "https://media.example/segment.ts")
            ),
            byteRange: nil
        )
        let playlist = "#EXTM3U\n#EXT-X-ENDLIST\n"
        let store = HLSResumeStore(destinationURL: destinationURL)
        let initial = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: makeIdentity(
                sourceURL: sourceURL,
                playlist: playlist,
                entityTag: "\"version-one\""
            ),
            resources: [resource],
            maximumTotalBytes: 100
        )
        try Data("STALE".utf8).write(to: initial.partialURL)
        try store.save(
            resourceCount: 1,
            nextResourceIndex: 1,
            assembledByteCount: 5
        )

        let restarted = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: makeIdentity(
                sourceURL: sourceURL,
                playlist: playlist,
                entityTag: "\"version-two\""
            ),
            resources: [resource],
            maximumTotalBytes: 100
        )

        #expect(restarted.nextResourceIndex == 0)
        #expect(restarted.assembledByteCount == 0)
        #expect(try Data(contentsOf: restarted.partialURL).isEmpty)
    }

    @Test("resume metadata fingerprints URLs and validators")
    func resumeMetadataDoesNotPersistSensitiveValues() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent("video.ts")
        let sourceURL = try #require(
            URL(
                string:
                    "https://media.example/playlist.m3u8?token=source-secret"
            )
        )
        let resource = HLSResourceTransfer(
            url: try #require(
                URL(
                    string:
                        "https://media.example/segment.ts?token=media-secret"
                )
            ),
            byteRange: nil
        )
        let entityTag = "\"private-validator\""
        _ = try HLSResumeStore(
            destinationURL: destinationURL
        ).prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: makeIdentity(
                sourceURL: sourceURL,
                playlist: "#EXTM3U\n#EXT-X-ENDLIST\n",
                entityTag: entityTag
            ),
            resources: [resource],
            maximumTotalBytes: 100
        )

        let manifestURL =
            directoryURL
            .appendingPathComponent(
                ".video.ts.hls-resume",
                isDirectory: true
            )
            .appendingPathComponent("manifest.json")
        let manifest = try String(
            contentsOf: manifestURL,
            encoding: .utf8
        )

        #expect(!manifest.contains(sourceURL.absoluteString))
        #expect(!manifest.contains(resource.url.absoluteString))
        #expect(!manifest.contains("source-secret"))
        #expect(!manifest.contains("media-secret"))
        #expect(!manifest.contains(entityTag))
    }

    @Test("a changed AES-128 key invalidates completed resource boundaries")
    func changedAES128KeyStartsCleanWorkspace() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL =
            directoryURL.appendingPathComponent("video.ts")
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let keyURL = try #require(
            URL(
                string:
                    "https://media.example/key.bin?token=key-secret"
            )
        )
        let resource = HLSResourceTransfer(
            url: try #require(
                URL(string: "https://media.example/segment.ts")
            ),
            byteRange: nil,
            encryption: HLSAES128Encryption(
                keyURL: keyURL,
                initializationVector: Data(repeating: 1, count: 16)
            )
        )
        let firstKey = Data(repeating: 2, count: 16)
        let changedKey = Data(repeating: 3, count: 16)
        let store = HLSResumeStore(destinationURL: destinationURL)
        let identity = makeIdentity(
            sourceURL: sourceURL,
            playlist: "#EXTM3U\n#EXT-X-ENDLIST\n"
        )
        let initial = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: identity,
            resources: [resource],
            aes128KeySet: HLSAES128KeySet(
                keysByURL: [keyURL: firstKey]
            ),
            maximumTotalBytes: 100
        )
        try Data("STALE".utf8).write(to: initial.partialURL)
        try store.save(
            resourceCount: 1,
            nextResourceIndex: 1,
            assembledByteCount: 5
        )

        let restarted = try store.prepare(
            sourceURL: sourceURL,
            mediaPlaylistIdentity: identity,
            resources: [resource],
            aes128KeySet: HLSAES128KeySet(
                keysByURL: [keyURL: changedKey]
            ),
            maximumTotalBytes: 100
        )

        #expect(restarted.nextResourceIndex == 0)
        #expect(restarted.assembledByteCount == 0)
        #expect(try Data(contentsOf: restarted.partialURL).isEmpty)
        let manifest = try String(
            contentsOf:
                directoryURL
                .appendingPathComponent(
                    ".video.ts.hls-resume",
                    isDirectory: true
                )
                .appendingPathComponent("manifest.json"),
            encoding: .utf8
        )
        #expect(!manifest.contains(keyURL.absoluteString))
        #expect(!manifest.contains("key-secret"))
        #expect(!manifest.contains(firstKey.base64EncodedString()))
        #expect(!manifest.contains(changedKey.base64EncodedString()))
    }

    @Test("a foreign resume directory is never deleted")
    func foreignResumeDirectoryIsPreserved() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent("video.ts")
        let foreignDirectoryURL = directoryURL.appendingPathComponent(
            ".video.ts.hls-resume",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: foreignDirectoryURL,
            withIntermediateDirectories: true
        )
        let foreignFileURL = foreignDirectoryURL.appendingPathComponent(
            "user-data"
        )
        try Data("KEEP".utf8).write(to: foreignFileURL)
        let sourceURL = try #require(
            URL(string: "https://media.example/playlist.m3u8")
        )
        let resource = HLSResourceTransfer(
            url: try #require(
                URL(string: "https://media.example/segment.ts")
            ),
            byteRange: nil
        )

        #expect(throws: (any Error).self) {
            try HLSResumeStore(
                destinationURL: destinationURL
            ).prepare(
                sourceURL: sourceURL,
                mediaPlaylistIdentity: makeIdentity(
                    sourceURL: sourceURL,
                    playlist: "#EXTM3U\n#EXT-X-ENDLIST\n"
                ),
                resources: [resource],
                maximumTotalBytes: 100
            )
        }
        #expect(try Data(contentsOf: foreignFileURL) == Data("KEEP".utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HLSResumeStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func makeIdentity(
        sourceURL: URL,
        playlist: String,
        entityTag: String? = nil,
        lastModified: String? = nil
    ) -> HLSContentIdentity {
        let response = HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "ETag": entityTag,
                "Last-Modified": lastModified,
            ].compactMapValues { $0 }
        )
        return HLSContentIdentity(
            finalURL: sourceURL,
            playlistData: Data(playlist.utf8),
            response: response
        )
    }
}
