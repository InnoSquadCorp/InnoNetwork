#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAudio

@Suite("HLS audio-mix processing tap")
struct HLSAudioMixProcessingTapTests {
    @Test("tap attachment is explicit, exclusive, and idempotent")
    @available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
    @MainActor
    func attachmentLifecycle() throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        let tap = try HLSAudioMixProcessingTap(
            playerItem: playerItem,
            preferredFormat: try .float32(),
            callbacks: HLSAudioMixProcessingCallbacks { _, _ in }
        )

        #expect(tap.isAttached)
        #expect(playerItem.audioMix === tap.audioMix)
        let parameters = try #require(tap.audioMix.inputParameters.first)
        #expect(parameters.trackID == 0)
        #expect(parameters.audioTapProcessor != nil)

        #expect(throws: HLSAudioMixProcessingError.audioMixAlreadyConfigured) {
            try HLSAudioMixProcessingTap(
                playerItem: playerItem,
                preferredFormat: .float32(),
                callbacks: HLSAudioMixProcessingCallbacks { _, _ in }
            )
        }

        tap.detach()
        tap.detach()

        #expect(!tap.isAttached)
        #expect(playerItem.audioMix == nil)
    }

    @Test("detachment preserves an application replacement audio mix")
    @available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
    @MainActor
    func preservesReplacementMix() throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        let tap = try HLSAudioMixProcessingTap(
            playerItem: playerItem,
            preferredFormat: try .float32(),
            callbacks: HLSAudioMixProcessingCallbacks { _, _ in }
        )
        let replacement = AVMutableAudioMix()
        playerItem.audioMix = replacement

        tap.detach()

        #expect(playerItem.audioMix?.inputParameters.isEmpty == true)
    }

    @Test("wrapper lifetime removes only its installed audio mix")
    @available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
    @MainActor
    func automaticDetachment() throws {
        let sourceURL = try #require(
            URL(string: "https://example.com/live.m3u8")
        )
        let playerItem = AVPlayerItem(url: sourceURL)
        var tap: HLSAudioMixProcessingTap? = try HLSAudioMixProcessingTap(
            playerItem: playerItem,
            preferredFormat: try .float32(),
            callbacks: HLSAudioMixProcessingCallbacks { _, _ in }
        )

        #expect(tap != nil)
        #expect(playerItem.audioMix != nil)
        tap = nil

        #expect(playerItem.audioMix == nil)
    }

    @Test("stream flags preserve MediaToolbox boundaries")
    func streamFlags() {
        let flags: HLSAudioMixStreamFlags = [
            .startOfStream,
            .endOfStream,
        ]

        #expect(flags.contains(.startOfStream))
        #expect(flags.contains(.endOfStream))
    }

    @Test("errors provide actionable redacted messages")
    func errorDescriptions() throws {
        let configured = HLSAudioMixProcessingError.audioMixAlreadyConfigured
        let creation = HLSAudioMixProcessingError.tapCreationFailed(status: -1)

        #expect(try #require(configured.errorDescription).contains("audio mix"))
        #expect(
            try #require(configured.recoverySuggestion).contains("Detach")
        )
        #expect(
            try #require(creation.errorDescription).contains("MediaToolbox")
        )
        let creationDescription = try #require(creation.errorDescription)
        #expect(!creationDescription.contains("-1"))
    }
}
#endif
