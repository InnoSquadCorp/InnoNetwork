import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS parser deterministic mutation gate")
struct HLSParserMutationTests {
    @Test("mutated playlists either preserve invariants or fail typed")
    func deterministicMutations() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/path/index.m3u8")
        )
        let resolver = PlaylistResolver()
        var generator = MutationGenerator(seed: 0x494E4E4F484C53)

        for seed in mutationSeeds {
            for _ in 0..<256 {
                let mutation = generator.mutate(seed)
                do {
                    let playlist = try resolver.resolve(
                        mutation,
                        relativeTo: sourceURL
                    )
                    verifyInvariants(
                        playlist,
                        sourceURL: sourceURL
                    )
                } catch is HLSDownloadError {
                    continue
                } catch {
                    Issue.record(
                        "Mutation escaped typed parsing errors: \(error)"
                    )
                }
            }
        }
    }

    private func verifyInvariants(
        _ playlist: HLSPlaylist,
        sourceURL: URL
    ) {
        #expect(playlist.sourceURL == sourceURL)
        switch playlist.kind {
        case .media:
            #expect(playlist.media != nil)
            #expect(playlist.variants.isEmpty)
            #expect(playlist.iFrameVariants.isEmpty)
            #expect(playlist.renditions.isEmpty)
        case .multivariant:
            #expect(playlist.media == nil)
        }
        #expect(
            playlist.variants.allSatisfy {
                $0.url.scheme != nil
            }
        )
        #expect(
            playlist.iFrameVariants.allSatisfy {
                $0.url.scheme != nil
            }
        )
        #expect(
            playlist.renditions.allSatisfy {
                $0.url?.scheme != nil || $0.url == nil
            }
        )
        #expect(
            playlist.lowLatency?.partialSegments.allSatisfy {
                $0.duration.isFinite && $0.duration > 0
            } ?? true
        )
        #expect(
            playlist.media?.resources.allSatisfy {
                guard let duration = $0.duration else {
                    return true
                }
                return duration.isFinite && duration >= 0
            } ?? true
        )
    }

    private let mutationSeeds = [
        """
        #EXTM3U
        #EXT-X-VERSION:9
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:9223372036854775700
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24,PART-HOLD-BACK=2
        #EXT-X-PART-INF:PART-TARGET=1
        #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
        #EXT-X-DATERANGE:ID="ad",CLASS="com.apple.hls.interstitial",START-DATE="2026-08-06T12:00:00Z",X-ASSET-URI="https://ads.example/ad.m3u8"
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        segment-0.m4s
        #EXT-X-PART:DURATION=1,URI="segment-1.0.m4s",INDEPENDENT=YES
        """,
        """
        #EXTM3U
        #EXT-X-VERSION:13
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="ko.m3u8",STABLE-RENDITION-ID="audio-ko"
        #EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="Example",LANGUAGE="en"
        #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://asset",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,AVERAGE-BANDWIDTH=2000000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="audio",STABLE-VARIANT-ID="main"
        video.m3u8
        """,
    ]
}

private struct MutationGenerator {
    private static let tokens: [UInt8] = [
        0x00, 0x09, 0x0A, 0x0D, 0x22, 0x23, 0x2C, 0x3A,
        0x3D, 0x5C, 0x7F,
    ]

    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func mutate(_ source: String) -> String {
        var bytes = Array(source.utf8)
        let operation = Int(next() % 4)
        let index = Int(next() % UInt64(max(1, bytes.count)))
        let token = Self.tokens[
            Int(next() % UInt64(Self.tokens.count))
        ]

        switch operation {
        case 0:
            if !bytes.isEmpty {
                bytes[index] = token
            }
        case 1:
            if !bytes.isEmpty {
                bytes.remove(at: index)
            }
        case 2:
            bytes.insert(token, at: min(index, bytes.count))
        default:
            guard !bytes.isEmpty else {
                break
            }
            let length = min(
                Int(next() % 16) + 1,
                bytes.count - index
            )
            bytes.insert(
                contentsOf: bytes[index..<(index + length)],
                at: index
            )
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
