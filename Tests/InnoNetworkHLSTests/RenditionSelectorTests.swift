import Foundation
import InnoNetworkHLS
import Testing

@Suite("HLS rendition selection")
struct RenditionSelectorTests {
    @Test("preferred language order wins within one group")
    func preferredLanguageWins() throws {
        let playlist = try makePlaylist()

        let selected = RenditionSelector().select(
            in: playlist,
            groupID: "audio",
            kind: .audio,
            policy: .preferredLanguages(["ja", "ko-KR"])
        )

        #expect(selected?.name == "Japanese")
    }

    @Test("language misses fall back to the declared default")
    func languageMissFallsBackToDefault() throws {
        let playlist = try makePlaylist()

        let selected = RenditionSelector().select(
            in: playlist,
            groupID: "audio",
            kind: .audio,
            policy: .preferredLanguages(["fr"])
        )

        #expect(selected?.name == "Korean")
    }

    @Test("disabled policy never selects a rendition")
    func disabledSelectsNothing() throws {
        let playlist = try makePlaylist()

        #expect(
            RenditionSelector().select(
                in: playlist,
                groupID: "audio",
                kind: .audio,
                policy: .disabled
            ) == nil
        )
    }

    @Test("an exact language tag wins before a broader playlist entry")
    func exactLanguageWinsBeforePrefixFallback() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [],
            renditions: [
                HLSRendition(
                    kind: .audio,
                    groupID: "audio",
                    name: "Generic English",
                    language: "en"
                ),
                HLSRendition(
                    kind: .audio,
                    groupID: "audio",
                    name: "US English",
                    language: "en-US"
                ),
            ]
        )

        let selected = RenditionSelector().select(
            in: playlist,
            groupID: "audio",
            kind: .audio,
            policy: .preferredLanguages(["en-US"])
        )

        #expect(selected?.name == "US English")
    }

    private func makePlaylist() throws -> HLSPlaylist {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        return HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [],
            renditions: [
                HLSRendition(
                    kind: .audio,
                    groupID: "audio",
                    name: "Korean",
                    language: "ko-KR",
                    isDefault: true,
                    isAutoselect: true
                ),
                HLSRendition(
                    kind: .audio,
                    groupID: "audio",
                    name: "Japanese",
                    language: "ja-JP",
                    isAutoselect: true
                ),
            ]
        )
    }
}
