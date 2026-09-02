import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS local playback source")
struct HLSLocalPlaybackSourceTests {
    @Test("a package-contained playlist survives persistence validation")
    func roundTrips() throws {
        let packageURL = URL(fileURLWithPath: "/tmp/episode.hlspkg")
        let entryURL = packageURL.appendingPathComponent("media/index.m3u8")
        let source = try HLSLocalPlaybackSource(
            packageDirectoryURL: packageURL,
            entryPlaylistURL: entryURL
        )

        let restored = try JSONDecoder().decode(
            HLSLocalPlaybackSource.self,
            from: JSONEncoder().encode(source)
        )

        #expect(restored == source)
        #expect(restored.packageDirectoryURL == packageURL)
        #expect(restored.entryPlaylistURL == entryURL)
    }

    @Test("non-local and unbounded package entry points are rejected")
    func rejectsUnsafeEntryPoints() throws {
        let packageURL = URL(fileURLWithPath: "/tmp/episode.hlspkg")

        #expect(throws: HLSLocalPlaybackSourceError.self) {
            try HLSLocalPlaybackSource(
                packageDirectoryURL: try #require(
                    URL(string: "https://media.example/episode")
                ),
                entryPlaylistURL: packageURL.appendingPathComponent(
                    "index.m3u8"
                )
            )
        }
        #expect(throws: HLSLocalPlaybackSourceError.self) {
            var components = try #require(
                URLComponents(
                    url: packageURL.appendingPathComponent("index.m3u8"),
                    resolvingAgainstBaseURL: false
                )
            )
            components.query = "token=secret"
            _ = try HLSLocalPlaybackSource(
                packageDirectoryURL: packageURL,
                entryPlaylistURL: try #require(components.url)
            )
        }
        #expect(throws: HLSLocalPlaybackSourceError.self) {
            try HLSLocalPlaybackSource(
                packageDirectoryURL: packageURL,
                entryPlaylistURL: URL(fileURLWithPath: "/tmp/index.m3u8")
            )
        }
        #expect(throws: HLSLocalPlaybackSourceError.self) {
            try HLSLocalPlaybackSource(
                packageDirectoryURL: URL(fileURLWithPath: "/"),
                entryPlaylistURL: URL(fileURLWithPath: "/index.m3u8")
            )
        }
        #expect(throws: HLSLocalPlaybackSourceError.self) {
            try HLSLocalPlaybackSource(
                packageDirectoryURL: packageURL,
                entryPlaylistURL: packageURL.appendingPathComponent(
                    "index.txt"
                )
            )
        }
        #expect(throws: HLSLocalPlaybackSourceError.self) {
            try HLSLocalPlaybackSource(
                packageDirectoryURL: try #require(
                    URL(string: "file:episode.hlspkg")
                ),
                entryPlaylistURL: try #require(
                    URL(string: "file:episode.hlspkg/index.m3u8")
                )
            )
        }
    }
}
