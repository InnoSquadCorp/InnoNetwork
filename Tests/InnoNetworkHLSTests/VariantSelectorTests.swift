import Foundation
import InnoNetworkHLS
import Testing

@Suite("HLS variant selection")
struct VariantSelectorTests {
    @Test("resolution wins before bandwidth")
    func selectsHighestResolution() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let lowURL = try #require(
            URL(string: "https://cdn.example/low.m3u8")
        )
        let highURL = try #require(
            URL(string: "https://cdn.example/high.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: lowURL,
                    bandwidth: 9_000_000,
                    width: 1_280,
                    height: 720
                ),
                HLSVariant(
                    url: highURL,
                    bandwidth: 4_000_000,
                    width: 1_920,
                    height: 1_080
                ),
            ]
        )

        let result = VariantSelector().highestQuality(in: playlist)

        #expect(result?.url == highURL)
    }

    @Test("average bandwidth breaks equal-resolution ties")
    func usesAverageBandwidthForTie() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let firstURL = try #require(
            URL(string: "https://cdn.example/first.m3u8")
        )
        let secondURL = try #require(
            URL(string: "https://cdn.example/second.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: firstURL,
                    bandwidth: 8_000_000,
                    averageBandwidth: 3_000_000,
                    width: 1_920,
                    height: 1_080
                ),
                HLSVariant(
                    url: secondURL,
                    bandwidth: 5_000_000,
                    averageBandwidth: 4_000_000,
                    width: 1_920,
                    height: 1_080
                ),
            ]
        )

        let result = VariantSelector().highestQuality(in: playlist)

        #expect(result?.url == secondURL)
    }

    @Test("untrusted resolution values cannot overflow")
    func handlesResolutionOverflow() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let hugeURL = try #require(
            URL(string: "https://cdn.example/huge.m3u8")
        )
        let normalURL = try #require(
            URL(string: "https://cdn.example/normal.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: hugeURL,
                    width: Int.max,
                    height: Int.max
                ),
                HLSVariant(
                    url: normalURL,
                    width: 1_920,
                    height: 1_080
                ),
            ]
        )

        let result = VariantSelector().highestQuality(in: playlist)

        #expect(result?.url == hugeURL)
    }

    @Test("lowest-bandwidth policy prefers the smallest advertised stream")
    func selectsLowestBandwidth() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let lowURL = try #require(
            URL(string: "https://cdn.example/low.m3u8")
        )
        let highURL = try #require(
            URL(string: "https://cdn.example/high.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: highURL,
                    bandwidth: 5_000_000,
                    width: 1_920,
                    height: 1_080
                ),
                HLSVariant(
                    url: lowURL,
                    bandwidth: 800_000,
                    width: 854,
                    height: 480
                ),
            ]
        )

        let result = VariantSelector().select(
            in: playlist,
            policy: .lowestBandwidth
        )

        #expect(result?.url == lowURL)
    }

    @Test("resolution constraint selects the best matching stream")
    func selectsWithinResolutionConstraint() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let hdURL = try #require(
            URL(string: "https://cdn.example/hd.m3u8")
        )
        let fullHDURL = try #require(
            URL(string: "https://cdn.example/full-hd.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: fullHDURL,
                    bandwidth: 4_000_000,
                    width: 1_920,
                    height: 1_080
                ),
                HLSVariant(
                    url: hdURL,
                    bandwidth: 2_000_000,
                    width: 1_280,
                    height: 720
                ),
            ]
        )

        let result = VariantSelector().select(
            in: playlist,
            policy: .maximumResolution(width: 1_280, height: 720)
        )

        #expect(result?.url == hdURL)
    }

    @Test("capability selection filters codecs and prefers dynamic range")
    func selectsCompatibleCodecAndPreferredVideoRange() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let sdrURL = try #require(
            URL(string: "https://cdn.example/sdr.m3u8")
        )
        let hdrURL = try #require(
            URL(string: "https://cdn.example/hdr.m3u8")
        )
        let unsupportedURL = try #require(
            URL(string: "https://cdn.example/unsupported.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: sdrURL,
                    bandwidth: 4_000_000,
                    width: 1_920,
                    height: 1_080,
                    codecs: ["hvc1.1.6.L120", "mp4a.40.2"],
                    videoRange: "SDR"
                ),
                HLSVariant(
                    url: hdrURL,
                    bandwidth: 3_000_000,
                    width: 1_280,
                    height: 720,
                    codecs: ["hvc1.2.4.L120", "mp4a.40.2"],
                    videoRange: "PQ"
                ),
                HLSVariant(
                    url: unsupportedURL,
                    bandwidth: 2_000_000,
                    width: 3_840,
                    height: 2_160,
                    codecs: ["av01.0.12M.10"],
                    videoRange: "PQ"
                ),
            ]
        )

        let selected = VariantSelector().select(
            in: playlist,
            policy: .compatible(
                HLSPlaybackCapabilities(
                    maximumWidth: 1_920,
                    maximumHeight: 1_080,
                    maximumBandwidth: 5_000_000,
                    supportedCodecPrefixes: ["hvc1", "mp4a"],
                    preferredVideoRanges: ["PQ", "SDR"]
                )
            )
        )

        #expect(selected?.url == hdrURL)
    }

    @Test("constrained policies do not silently exceed their limits")
    func returnsNilWhenConstraintCannotBeSatisfied() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let highURL = try #require(
            URL(string: "https://cdn.example/high.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: highURL,
                    bandwidth: 5_000_000,
                    width: 1_920,
                    height: 1_080
                )
            ]
        )

        #expect(
            VariantSelector().select(
                in: playlist,
                policy: .maximumBandwidth(1_000_000)
            ) == nil
        )
        #expect(
            VariantSelector().select(
                in: playlist,
                policy: .maximumResolution(width: 640, height: 480)
            ) == nil
        )
    }

    @Test("non-positive bandwidth is not treated as a valid constraint match")
    func ignoresNonPositiveBandwidth() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let invalidURL = try #require(
            URL(string: "https://cdn.example/invalid.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: invalidURL,
                    bandwidth: -1,
                    width: 640,
                    height: 360
                )
            ]
        )

        #expect(
            VariantSelector().select(
                in: playlist,
                policy: .maximumBandwidth(1_000_000)
            ) == nil
        )
        #expect(
            VariantSelector().select(
                in: playlist,
                policy: .lowestBandwidth
            ) == nil
        )
        #expect(
            VariantSelector().select(
                in: playlist,
                policy: .maximumResolution(width: 640, height: 360)
            )?.url == invalidURL
        )
    }

    @Test("invalid average bandwidth falls back to a valid peak bandwidth")
    func fallsBackFromInvalidAverageBandwidth() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let variantURL = try #require(
            URL(string: "https://cdn.example/valid-peak.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: variantURL,
                    bandwidth: 800_000,
                    averageBandwidth: -1
                )
            ]
        )

        #expect(
            VariantSelector().select(
                in: playlist,
                policy: .maximumBandwidth(1_000_000)
            )?.url == variantURL
        )
    }

    @Test("non-positive dimensions cannot satisfy a resolution constraint")
    func ignoresNonPositiveDimensions() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let invalidURL = try #require(
            URL(string: "https://cdn.example/invalid.m3u8")
        )
        let playlist = HLSPlaylist(
            sourceURL: sourceURL,
            kind: .multivariant,
            variants: [
                HLSVariant(
                    url: invalidURL,
                    bandwidth: 800_000,
                    width: -1,
                    height: 360
                )
            ]
        )

        #expect(
            VariantSelector().select(
                in: playlist,
                policy: .maximumResolution(width: 640, height: 360)
            ) == nil
        )
    }
}
