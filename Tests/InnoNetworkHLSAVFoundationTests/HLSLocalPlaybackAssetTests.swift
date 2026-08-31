#if canImport(AVFoundation) && canImport(Network)
import AVFoundation
import Foundation
import InnoNetworkHLS
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import InnoNetworkHLSAVFoundation

@MainActor
@Suite("Local HLS playback asset", .serialized)
struct HLSLocalPlaybackAssetTests {
    @Test("the loopback bridge serves frozen playlists and byte ranges")
    func servesFrozenPlaylistAndRanges() async throws {
        let packageURL = try makeRuntimePackage()
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        let source = try playbackSource(packageURL)
        let originalPlaylist = try Data(
            contentsOf: source.entryPlaylistURL
        )
        let asset = try await HLSLocalPlaybackAsset(source: source)
        defer {
            asset.close()
        }

        try Data(
            "#EXTM3U\n#EXTINF:1,\nhttps://media.example/escape.ts\n"
                .utf8
        ).write(to: source.entryPlaylistURL, options: .atomic)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let (playlistData, response) = try await session.data(
            from: asset.urlAsset.url
        )
        #expect(
            (response as? HTTPURLResponse)?.statusCode == 200
        )
        #expect(playlistData == originalPlaylist)

        var rangeRequest = URLRequest(url: asset.urlAsset.url)
        rangeRequest.setValue("bytes=0-6", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await session.data(
            for: rangeRequest
        )
        #expect(
            (rangeResponse as? HTTPURLResponse)?.statusCode == 206
        )
        #expect(rangeData == originalPlaylist.prefix(7))
        #expect(
            (rangeResponse as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Range")
                == "bytes 0-6/\(originalPlaylist.count)"
        )

        var headRequest = URLRequest(url: asset.urlAsset.url)
        headRequest.httpMethod = "HEAD"
        let (headData, headResponse) = try await session.data(
            for: headRequest
        )
        #expect(
            (headResponse as? HTTPURLResponse)?.statusCode == 200
        )
        #expect(headData.isEmpty)
    }

    @Test("remote and package-escaping playlist references are rejected")
    func rejectsUnsafePlaylistReferences() async throws {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageURL = parentURL.appendingPathComponent(
            "unsafe.hlspkg",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let entryURL = packageURL.appendingPathComponent("index.m3u8")
        try Data(
            "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttps://media.example/escape.ts\n#EXT-X-ENDLIST\n"
                .utf8
        ).write(to: entryURL)
        let remoteSource = try HLSLocalPlaybackSource(
            packageDirectoryURL: packageURL,
            entryPlaylistURL: entryURL
        )

        await #expect(
            throws: HLSLocalPlaybackAssetError.unsafePackageContents
        ) {
            _ = try await HLSLocalPlaybackAsset(
                source: remoteSource
            )
        }

        try Data(
            "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n../escape.ts\n#EXT-X-ENDLIST\n"
                .utf8
        ).write(to: entryURL, options: .atomic)
        await #expect(
            throws: HLSLocalPlaybackAssetError.unsafePackageContents
        ) {
            _ = try await HLSLocalPlaybackAsset(
                source: remoteSource
            )
        }

        try Data(
            "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n%2E%2E%2Fescape.ts\n#EXT-X-ENDLIST\n"
                .utf8
        ).write(to: entryURL, options: .atomic)
        await #expect(
            throws: HLSLocalPlaybackAssetError.unsafePackageContents
        ) {
            _ = try await HLSLocalPlaybackAsset(
                source: remoteSource
            )
        }

        let childURL = packageURL.appendingPathComponent("media.m3u8")
        try Data(
            "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n"
                .utf8
        ).write(to: childURL)
        try Data(
            "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"steering.json\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia.m3u8\n"
                .utf8
        ).write(to: entryURL, options: .atomic)
        await #expect(
            throws: HLSLocalPlaybackAssetError.unsafePackageContents
        ) {
            _ = try await HLSLocalPlaybackAsset(
                source: remoteSource
            )
        }
    }

    @Test("package admission preserves actionable failure categories")
    func classifiesPackageAdmissionFailures() async throws {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let missingPackageURL = parentURL.appendingPathComponent(
            "missing.hlspkg",
            isDirectory: true
        )
        let missingPackageSource = try HLSLocalPlaybackSource(
            packageDirectoryURL: missingPackageURL,
            entryPlaylistURL: missingPackageURL.appendingPathComponent(
                "index.m3u8"
            )
        )
        await #expect(
            throws: HLSLocalPlaybackAssetError.packageUnavailable
        ) {
            _ = try await HLSLocalPlaybackAsset(
                source: missingPackageSource
            )
        }

        let packageURL = parentURL.appendingPathComponent(
            "episode.hlspkg",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        let missingEntrySource = try HLSLocalPlaybackSource(
            packageDirectoryURL: packageURL,
            entryPlaylistURL: packageURL.appendingPathComponent(
                "index.m3u8"
            )
        )
        await #expect(
            throws: HLSLocalPlaybackAssetError.entryPlaylistUnavailable
        ) {
            _ = try await HLSLocalPlaybackAsset(
                source: missingEntrySource
            )
        }

        let externalPlaylistURL = parentURL.appendingPathComponent(
            "external.m3u8"
        )
        try Data(
            "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n"
                .utf8
        ).write(to: externalPlaylistURL)
        try FileManager.default.createSymbolicLink(
            at: missingEntrySource.entryPlaylistURL,
            withDestinationURL: externalPlaylistURL
        )
        await #expect(
            throws: HLSLocalPlaybackAssetError.unsafePackageContents
        ) {
            _ = try await HLSLocalPlaybackAsset(
                source: missingEntrySource
            )
        }
    }

    @Test("a package resource symbolic link is forbidden per request")
    func rejectsResourceSymbolicLink() async throws {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageURL = parentURL.appendingPathComponent(
            "episode.hlspkg",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let entryURL = packageURL.appendingPathComponent("index.m3u8")
        try Data(
            "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n"
                .utf8
        ).write(to: entryURL)
        let externalResourceURL = parentURL.appendingPathComponent(
            "external.ts"
        )
        try Data("external".utf8).write(to: externalResourceURL)
        try FileManager.default.createSymbolicLink(
            at: packageURL.appendingPathComponent("segment.ts"),
            withDestinationURL: externalResourceURL
        )
        let asset = try await HLSLocalPlaybackAsset(
            source: try playbackSource(packageURL)
        )
        defer {
            asset.close()
        }
        let segmentURL = asset.urlAsset.url
            .deletingLastPathComponent()
            .appendingPathComponent("segment.ts")
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
        }

        let (_, response) = try await session.data(from: segmentURL)

        #expect((response as? HTTPURLResponse)?.statusCode == 403)
    }

}

@MainActor
@Suite("Local HLS playback runtime", .serialized)
struct HLSLocalPlaybackRuntimeTests {
    @Test(
        "AVPlayer advances through the local bridge",
        .timeLimit(.minutes(1))
    )
    func avPlayerAdvances() async throws {
        let packageURL = try makeRuntimePackage()
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        let asset = try await HLSLocalPlaybackAsset(
            source: try playbackSource(packageURL)
        )
        let item = AVPlayerItem(asset: asset.urlAsset)
        let player = AVPlayer(playerItem: item)
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            asset.close()
        }

        player.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline,
            item.status != .failed,
            player.currentTime().seconds <= 0.1
        {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(item.error == nil)
        #expect(player.currentTime().seconds > 0.1)
    }
}

private func playbackSource(
    _ packageURL: URL
) throws -> HLSLocalPlaybackSource {
    try HLSLocalPlaybackSource(
        packageDirectoryURL: packageURL,
        entryPlaylistURL: packageURL.appendingPathComponent(
            "index.m3u8"
        )
    )
}

private func makeRuntimePackage() throws -> URL {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/HLSRuntime/audio-fmp4")
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "\(UUID().uuidString).hlspkg",
            isDirectory: true
        )
    try FileManager.default.copyItem(
        at: fixtureURL,
        to: packageURL
    )
    return packageURL
}
#endif
