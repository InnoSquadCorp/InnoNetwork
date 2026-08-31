import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS interstitial presentation metadata")
struct HLSInterstitialPresentationTests {
    @Test("coordination, timeline, restriction, and skip metadata are typed")
    func parsesPresentationMetadata() throws {
        let interstitial = try parseInterstitial(
            """
            X-CONTENT-MAY-VARY="NO",X-TIMELINE-OCCUPIES="RANGE",X-TIMELINE-STYLE="PRIMARY",X-RESTRICT="SKIP,JUMP,FUTURE",X-SKIP-CONTROL-OFFSET=5,X-SKIP-CONTROL-DURATION=20,X-SKIP-CONTROL-LABEL-ID="Exit_Label"
            """
        )

        #expect(interstitial.contentVariability == .sameForAllPlayers)
        #expect(interstitial.timelineOccupancy == .range)
        #expect(interstitial.timelineStyle == .primary)
        #expect(interstitial.navigationRestrictions == [.skip, .jump])
        #expect(
            interstitial.skipControl
                == HLSInterstitialSkipControl(
                    offset: 5,
                    duration: 20,
                    labelID: "Exit_Label"
                )
        )
    }

    @Test("missing and future presentation values use specification defaults")
    func defaultsFuturePresentationMetadata() throws {
        let defaults = try parseInterstitial("")
        let explicitVariation = try parseInterstitial(
            "X-CONTENT-MAY-VARY=\"YES\""
        )
        let future = try parseInterstitial(
            """
            X-CONTENT-MAY-VARY="FUTURE",X-TIMELINE-OCCUPIES="FUTURE",X-TIMELINE-STYLE="FUTURE",X-RESTRICT="FUTURE-2,FUTURE"
            """
        )

        #expect(defaults.contentVariability == .mayVary)
        #expect(explicitVariation.contentVariability == .mayVary)
        #expect(defaults.timelineOccupancy == .point)
        #expect(defaults.timelineStyle == .highlight)
        #expect(defaults.navigationRestrictions.isEmpty)
        #expect(defaults.skipControl == nil)
        #expect(future.timelineOccupancy == .point)
        #expect(future.timelineStyle == .highlight)
        #expect(future.navigationRestrictions.isEmpty)
        #expect(future.contentVariability == .mayVary)
    }

    @Test(
        "invalid interstitial presentation values fail typed",
        arguments: [
            "X-CONTENT-MAY-VARY=NO",
            "X-TIMELINE-OCCUPIES=POINT",
            "X-TIMELINE-STYLE=HIGHLIGHT",
            "X-RESTRICT=SKIP",
            "X-RESTRICT=\"SKIP,,JUMP\"",
            "X-RESTRICT=\"skip\"",
            "X-SKIP-CONTROL-OFFSET=\"5\"",
            "X-SKIP-CONTROL-OFFSET=1.5",
            "X-SKIP-CONTROL-DURATION=-1",
            "X-SKIP-CONTROL-LABEL-ID=Exit",
            "X-SKIP-CONTROL-LABEL-ID=\"Exit1\"",
            "X-SKIP-CONTROL-OFFSET=18446744073709551616",
        ]
    )
    func rejectsInvalidPresentationMetadata(
        _ attributes: String
    ) throws {
        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try parseInterstitial(attributes)
        }
    }

    @Test(
        "invalid asset-list skip-control overrides fail typed",
        arguments: [
            "{}",
            #"{"OFFSET":-1}"#,
            #"{"OFFSET":1.5}"#,
            #"{"OFFSET":null}"#,
            #"{"LABEL-ID":"Exit1"}"#,
            "[]",
        ]
    )
    func rejectsInvalidAssetListSkipControl(
        _ skipControl: String
    ) {
        let data = Data(
            """
            {
              "ASSETS": [
                {"URI":"https://ads.example/ad.m3u8","DURATION":1}
              ],
              "SKIP-CONTROL": \(skipControl)
            }
            """.utf8
        )

        #expect(
            throws:
                HLSExternalResourceError
                .invalidInterstitialAssetList
        ) {
            try HLSInterstitialAssetListDecoder.decode(
                data,
                maximumAssetCount: 1
            )
        }
    }

    private func parseInterstitial(
        _ attributes: String
    ) throws -> HLSInterstitial {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let suffix = attributes.isEmpty ? "" : ",\(attributes)"
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-31T00:00:00Z
            #EXTINF:6,
            segment.ts
            #EXT-X-DATERANGE:ID="ad",CLASS="com.apple.hls.interstitial",START-DATE="2026-08-31T00:00:00Z",X-ASSET-URI="https://ads.example/ad.m3u8"\(suffix)
            """,
            relativeTo: sourceURL
        )
        return try #require(playlist.dateRanges.first?.interstitial)
    }
}
