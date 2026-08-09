import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS parser scaling gate", .serialized)
struct HLSParserScalingTests {
    @Test("doubling a large playlist stays below quadratic growth")
    func nearLinearScaling() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/large.m3u8")
        )
        let resolver = PlaylistResolver()
        let small = makePlaylist(segmentCount: 400)
        let large = makePlaylist(segmentCount: 800)

        _ = try resolver.resolve(small, relativeTo: sourceURL)
        _ = try resolver.resolve(large, relativeTo: sourceURL)

        var smallSamples: [Double] = []
        var largeSamples: [Double] = []
        for sample in 0..<5 {
            if sample.isMultiple(of: 2) {
                smallSamples.append(
                    try measureBatch(
                        small,
                        segmentCount: 400,
                        resolver: resolver,
                        sourceURL: sourceURL
                    )
                )
                largeSamples.append(
                    try measureBatch(
                        large,
                        segmentCount: 800,
                        resolver: resolver,
                        sourceURL: sourceURL
                    )
                )
            } else {
                largeSamples.append(
                    try measureBatch(
                        large,
                        segmentCount: 800,
                        resolver: resolver,
                        sourceURL: sourceURL
                    )
                )
                smallSamples.append(
                    try measureBatch(
                        small,
                        segmentCount: 400,
                        resolver: resolver,
                        sourceURL: sourceURL
                    )
                )
            }
        }

        let smallMedian = median(smallSamples)
        let largeMedian = median(largeSamples)
        #expect(smallMedian > 0)
        // The ratio is the primary regression signal. This broad wall-clock
        // ceiling catches a runaway parser without coupling CI to one CPU.
        #expect(largeMedian < 10)
        #expect(largeMedian / smallMedian < 3.5)
    }

    private func makePlaylist(
        segmentCount: Int
    ) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:9",
            "#EXT-X-TARGETDURATION:4",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        lines.reserveCapacity(segmentCount * 2 + 6)
        for index in 0..<segmentCount {
            lines.append("#EXTINF:4,")
            lines.append("segment-\(index).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n")
    }

    private func measureBatch(
        _ playlist: String,
        segmentCount: Int,
        resolver: PlaylistResolver,
        sourceURL: URL
    ) throws -> Double {
        var parsedSegmentCount = 0
        let elapsed = try elapsedSeconds {
            for _ in 0..<8 {
                parsedSegmentCount =
                    try resolver.resolve(
                        playlist,
                        relativeTo: sourceURL
                    ).media?.resources.count ?? 0
            }
        }
        #expect(parsedSegmentCount == segmentCount)
        return elapsed
    }

    private func elapsedSeconds(
        _ operation: () throws -> Void
    ) rethrows -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try operation()
        let elapsed = start.duration(to: clock.now)
        return
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds)
            / 1_000_000_000_000_000_000
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
