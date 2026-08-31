#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS playback asset configuration")
struct HLSPlaybackAssetConfiguratorTests {
    @Test("CMCD availability maps requested policy without hidden fallback")
    func resolvesAvailability() {
        #expect(
            HLSPlaybackAssetConfigurator.resolvedStatus(
                for: .enabled,
                isSupported: false
            ) == .unavailable
        )
        #expect(
            HLSPlaybackAssetConfigurator.resolvedStatus(
                for: .disabled,
                isSupported: false
            ) == .disabled
        )
        #expect(
            HLSPlaybackAssetConfigurator.resolvedStatus(
                for: .enabled,
                isSupported: true
            ) == .enabled
        )
    }

    @MainActor
    @Test("CMCD policy is reversible without taking asset ownership")
    func appliesCommonMediaClientDataPolicy() throws {
        let asset = AVURLAsset(
            url: try #require(
                URL(string: "https://media.example/live.m3u8")
            )
        )
        let configurator = HLSPlaybackAssetConfigurator()

        #expect(configurator.apply(to: asset) == .disabled)
        #if os(watchOS)
        #expect(configurator.apply(.enabled, to: asset) == .unavailable)
        #else
        if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) {
            #expect(
                !asset.resourceLoader
                    .sendsCommonMediaClientDataAsHTTPHeaders
            )
            #expect(configurator.apply(.enabled, to: asset) == .enabled)
            #expect(
                asset.resourceLoader
                    .sendsCommonMediaClientDataAsHTTPHeaders
            )
            #expect(configurator.apply(.disabled, to: asset) == .disabled)
            #expect(
                !asset.resourceLoader
                    .sendsCommonMediaClientDataAsHTTPHeaders
            )
        } else {
            #expect(configurator.apply(.enabled, to: asset) == .unavailable)
        }
        #endif
    }
}
#endif
