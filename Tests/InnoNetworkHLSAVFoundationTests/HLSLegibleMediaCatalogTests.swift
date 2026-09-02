#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS legible media catalog")
struct HLSLegibleMediaCatalogTests {
    @Test("property-list identities are deterministic and value redacted")
    func propertyListIdentitiesAreDeterministic() throws {
        let first =
            try HLSPlaybackConfigurator
            .legibleMediaOptionID(
                forPropertyList: [
                    "language": "en",
                    "uri": "https://media.example/subtitles.m3u8?token=secret",
                ]
            )
        let repeated =
            try HLSPlaybackConfigurator
            .legibleMediaOptionID(
                forPropertyList: [
                    "uri": "https://media.example/subtitles.m3u8?token=secret",
                    "language": "en",
                ]
            )
        let other =
            try HLSPlaybackConfigurator
            .legibleMediaOptionID(
                forPropertyList: ["language": "ko"]
            )

        #expect(first == repeated)
        #expect(first != other)
        #expect(
            String(reflecting: first).contains("secret") == false
        )
    }

    @Test("invalid and ambiguous option identities fail typed")
    func invalidAndAmbiguousIdentitiesFailTyped() throws {
        #expect(
            throws:
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(.subtitles)
        ) {
            try HLSPlaybackConfigurator.legibleMediaOptionID(
                forPropertyList: NSObject()
            )
        }

        let first = HLSLegibleMediaOptionID(fingerprint: "first")
        let second = HLSLegibleMediaOptionID(fingerprint: "second")
        #expect(
            try HLSPlaybackConfigurator
                .uniqueLegibleMediaOptionIndex(
                    for: second,
                    in: [first, second]
                ) == 1
        )
        #expect(
            throws:
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(.subtitles)
        ) {
            try HLSPlaybackConfigurator
                .validateUniqueLegibleMediaOptionIDs([first, first])
        }
        #expect(
            throws:
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(.subtitles)
        ) {
            try HLSPlaybackConfigurator
                .uniqueLegibleMediaOptionIndex(
                    for: first,
                    in: [first, first]
                )
        }
    }

    @MainActor
    @Test("assets without legible media produce an empty catalog")
    func emptyCatalogForAssetWithoutLegibleMedia() async throws {
        let item = AVPlayerItem(asset: AVMutableComposition())

        let catalog = try await HLSPlaybackConfigurator()
            .legibleMediaCatalog(for: item)

        #expect(catalog.options.isEmpty)
        #expect(catalog.allowsEmptySelection)
    }

    @MainActor
    @Test("selection fails typed when the current asset has no group")
    func selectionRequiresCurrentLegibleGroup() async {
        let item = AVPlayerItem(asset: AVMutableComposition())

        await #expect(
            throws:
                HLSPlaybackConfigurationError
                .mediaSelectionGroupUnavailable(.subtitles)
        ) {
            try await HLSPlaybackConfigurator().selectLegibleMedia(
                .disabled,
                on: item
            )
        }
    }

    @Test("catalog values retain UI and provenance state across tasks")
    func catalogIsSendableValueState() async {
        let option = HLSLegibleMediaOption(
            id: HLSLegibleMediaOptionID(fingerprint: "option"),
            displayName: "English SDH",
            languageTag: "en-US",
            kind: .subtitles,
            provenance: [.machineGenerated, .translated],
            features: [
                .transcribesSpokenDialogue,
                .describesMusicAndSound,
            ],
            isSelected: true,
            isDefault: false
        )
        let catalog = HLSLegibleMediaCatalog(
            options: [option],
            allowsEmptySelection: true
        )

        let copied = await Task.detached { catalog }.value

        #expect(copied == catalog)
        #expect(copied.options[0].isSelected)
        #expect(copied.options[0].provenance.contains(.translated))
    }
}
#endif
