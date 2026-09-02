import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS timeline metadata")
struct HLSTimelineTests {
    @Test("start, program time, and consolidated Date Ranges are typed")
    func resolvesTimelineMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod/index.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-START:TIME-OFFSET=-3.5,PRECISE=YES
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00.000Z
            #EXTINF:6,
            segment-0.ts
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:06
            #EXTINF:6,
            segment-1.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="ad-1",CLASS="com.apple.hls.interstitial",START-DATE="2026-08-06T12:00:04.000Z",DURATION=15
            #EXT-X-DATERANGE:ID="ad-1",X-ASSET-URI="https://ads.example/ad.m3u8",X-RESUME-OFFSET=0,X-PLAYOUT-LIMIT=14.5,CUE="ONCE"
            #EXT-X-DATERANGE:ID="schedule",CLASS="com.apple.hls.daterange-schedule",START-DATE="2026-08-06T12:00:00.000Z",END-DATE="2026-08-06T12:00:12.000Z",DURATION=12,X-URI="schedule.json"
            """,
            relativeTo: sourceURL
        )

        #expect(
            playlist.preferredStartPosition
                == HLSPreferredStartPosition(
                    timeOffset: -3.5,
                    isPrecise: true
                )
        )
        #expect(playlist.programDateTimes.count == 2)
        #expect(playlist.programDateTimes[0].segmentIndex == 0)
        #expect(playlist.programDateTimes[1].segmentIndex == 1)
        #expect(
            playlist.programDateTimes[1].date.timeIntervalSince(
                playlist.programDateTimes[0].date
            ) == 6
        )

        let interstitial = try #require(
            playlist.dateRanges.first?.interstitial
        )
        #expect(playlist.dateRanges.count == 2)
        #expect(playlist.dateRanges[0].duration == 15)
        #expect(playlist.dateRanges[0].cues == [.once])
        #expect(interstitial.resumeOffset == 0)
        #expect(interstitial.playoutLimit == 14.5)
        #expect(
            interstitial.source
                == .asset(
                    try #require(
                        URL(string: "https://ads.example/ad.m3u8")
                    )
                )
        )
        #expect(
            playlist.dateRanges[1].externalResource?.url.absoluteString
                == "https://media.example/vod/schedule.json"
        )
        #expect(
            playlist.dateRanges[0].extensionAttributeNames
                == [
                    "X-ASSET-URI",
                    "X-PLAYOUT-LIMIT",
                    "X-RESUME-OFFSET",
                ]
        )
        #expect(
            playlist.media?.unsupportedFeatures
                == [
                    .interstitialResource,
                    .dateRangeExternalResource,
                ]
        )
    }

    @Test("EXT-X-START is also available on multivariant playlists")
    func resolvesMultivariantStartPosition() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-START:TIME-OFFSET=10
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(
            playlist.preferredStartPosition
                == HLSPreferredStartPosition(timeOffset: 10)
        )
        #expect(playlist.programDateTimes.isEmpty)
        #expect(playlist.dateRanges.isEmpty)
    }

    @Test(
        "invalid time and Date Range combinations are rejected",
        arguments: [
            """
            #EXTM3U
            #EXT-X-DATERANGE:ID="missing-time",START-DATE="2026-08-06T12:00:00Z"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="mismatch",START-DATE="2026-08-06T12:00:00Z",END-DATE="2026-08-06T12:00:02Z",DURATION=1
            """,
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="duplicate",START-DATE="2026-08-06T12:00:00Z",CLASS="one"
            #EXT-X-DATERANGE:ID="duplicate",CLASS="two"
            """,
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="late-start",CLASS="chapter"
            #EXT-X-DATERANGE:ID="late-start",START-DATE="2026-08-06T12:00:00Z"
            """,
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="next",CLASS="chapter",START-DATE="2026-08-06T12:00:00Z",DURATION=1,END-ON-NEXT=YES
            """,
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="ad",CLASS="com.apple.hls.interstitial",START-DATE="2026-08-06T12:00:00Z",X-ASSET-URI="relative.m3u8"
            """,
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            """,
            """
            #EXTM3U
            #EXT-X-START:TIME-OFFSET=1
            #EXT-X-START:TIME-OFFSET=2
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-START:TIME-OFFSET=1,PRECISE="YES"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="schedule",CLASS="com.apple.hls.daterange-schedule",START-DATE="2026-08-06T12:00:00Z",DURATION=1
            """,
        ]
    )
    func rejectsInvalidTimeline(_ source: String) throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                source,
                relativeTo: sourceURL
            )
        }
    }

    @Test("external timeline resources are explicit capability failures")
    func diagnosesExternalResources() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/vod.m3u8")
        )
        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="ad",CLASS="com.apple.hls.interstitial",START-DATE="2026-08-06T12:00:00Z",X-ASSET-LIST="assets.json"
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(!inspection.canDownloadAsSingleFile)
        #expect(!inspection.canCreateOfflinePackage)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .mediaFeatureUnsupported
                    && $0.mediaFeature == .interstitialResource
                    && $0.lineNumber == 6
            }
        )
    }
}
