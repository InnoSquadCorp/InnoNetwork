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

    @Test("subtitle provenance never changes audio selection")
    func provenanceDoesNotAffectAudio() throws {
        let playlist = try makePlaylist()

        let selected = RenditionSelector().select(
            in: playlist,
            groupID: "audio",
            kind: .audio,
            policy: .defaultOrFirst,
            subtitleProvenance: HLSSubtitleProvenancePolicy(
                machineGenerated: .excluded,
                translation: .excluded
            )
        )

        #expect(selected?.name == "Korean")
    }

    @Test("generated and translated characteristics stay typed")
    func exposesTypedProvenance() {
        let rendition = HLSRendition(
            kind: .subtitles,
            groupID: "subs",
            name: "Translated",
            characteristics: [
                "public.machine-generated",
                "public.translation",
                "example.custom",
            ]
        )

        #expect(rendition.isMachineGenerated)
        #expect(rendition.isTranslated)
        #expect(rendition.hasCharacteristic(.translation))
        #expect(
            rendition.mediaCharacteristics
                == [
                    .machineGenerated,
                    .translation,
                    HLSMediaCharacteristic(rawValue: "example.custom"),
                ]
        )
    }

    @Test("subtitle provenance composes preference and exclusion")
    func selectsSubtitleProvenance() throws {
        let playlist = try makeSubtitlePlaylist()
        let selector = RenditionSelector()

        let translated = selector.select(
            in: playlist,
            groupID: "subs",
            kind: .subtitles,
            policy: .defaultOrFirst,
            subtitleProvenance: HLSSubtitleProvenancePolicy(
                translation: .preferred
            )
        )
        let generated = selector.select(
            in: playlist,
            groupID: "subs",
            kind: .subtitles,
            policy: .defaultOrFirst,
            subtitleProvenance: HLSSubtitleProvenancePolicy(
                machineGenerated: .preferred,
                translation: .excluded
            )
        )
        let authored = selector.select(
            in: playlist,
            groupID: "subs",
            kind: .subtitles,
            policy: .defaultOrFirst,
            subtitleProvenance: HLSSubtitleProvenancePolicy(
                machineGenerated: .excluded
            )
        )

        #expect(translated?.name == "Translated")
        #expect(generated?.name == "Generated")
        #expect(authored?.name == "Authored")
    }

    @Test("an explicit subtitle language stays above provenance")
    func languageStaysAboveProvenance() throws {
        let playlist = try makeSubtitlePlaylist()

        let selected = RenditionSelector().select(
            in: playlist,
            groupID: "subs",
            kind: .subtitles,
            policy: .preferredLanguages(["ko"]),
            subtitleProvenance: HLSSubtitleProvenancePolicy(
                translation: .preferred
            )
        )

        #expect(selected?.name == "Authored")
    }

    @Test("neutral provenance preserves source-order language and name ties")
    func neutralProvenancePreservesLegacyTies() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [],
            renditions: [
                HLSRendition(
                    kind: .subtitles,
                    groupID: "subs",
                    name: "Duplicate",
                    language: "en"
                ),
                HLSRendition(
                    kind: .subtitles,
                    groupID: "subs",
                    name: "Duplicate",
                    language: "en",
                    isDefault: true,
                    isAutoselect: true
                ),
            ]
        )
        let selector = RenditionSelector()

        let language = selector.select(
            in: playlist,
            groupID: "subs",
            kind: .subtitles,
            policy: .preferredLanguages(["en"])
        )
        let name = selector.select(
            in: playlist,
            groupID: "subs",
            kind: .subtitles,
            policy: .named("Duplicate")
        )

        #expect(language == playlist.renditions[0])
        #expect(name == playlist.renditions[0])
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
                    characteristics: [
                        "public.machine-generated"
                    ],
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

    private func makeSubtitlePlaylist() throws -> HLSPlaylist {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        return HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [],
            renditions: [
                HLSRendition(
                    kind: .subtitles,
                    groupID: "subs",
                    name: "Authored",
                    language: "ko",
                    isDefault: true,
                    isAutoselect: true
                ),
                HLSRendition(
                    kind: .subtitles,
                    groupID: "subs",
                    name: "Generated",
                    language: "en",
                    characteristics: [
                        "public.machine-generated"
                    ],
                    isAutoselect: true
                ),
                HLSRendition(
                    kind: .subtitles,
                    groupID: "subs",
                    name: "Translated",
                    language: "es",
                    characteristics: [
                        "public.machine-generated",
                        "public.translation",
                    ],
                    isAutoselect: true
                ),
            ]
        )
    }
}
