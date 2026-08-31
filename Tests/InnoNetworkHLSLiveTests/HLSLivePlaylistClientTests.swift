import Foundation
import InnoNetworkHLS
import Testing
import os

@testable import InnoNetworkHLSLive

// Network-backed live tests share HLSLiveURLProtocol's deterministic response
// registry, so they intentionally live under one serialization boundary.
@Suite("HLS live networking", .serialized)
struct HLSLivePlaylistClientTests {
    @Test("HTTP freshness is typed and contributes to live health")
    func exposesHTTPFreshness() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/freshness.m3u8")
        )
        let measuredAt = Date(timeIntervalSince1970: 110)
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                segment.ts
                """,
                headers: [
                    "Date": "Thu, 01 Jan 1970 00:01:40 GMT",
                    "Last-Modified": "Thu, 01 Jan 1970 00:01:00 GMT",
                    "Age": "5",
                ]
            ),
            for: sourceURL
        )
        let client = HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        )

        let snapshot = try await client.snapshot(from: sourceURL)
        let freshness = try #require(snapshot.httpFreshness)

        #expect(freshness.measuredAt == measuredAt)
        #expect(freshness.responseDate == Date(timeIntervalSince1970: 100))
        #expect(freshness.lastModified == Date(timeIntervalSince1970: 60))
        #expect(freshness.reportedAge == 5)
        #expect(freshness.estimatedResponseAge == 10)
        #expect(freshness.estimatedPlaylistAge == 50)

        var analyzer = HLSLiveHealthAnalyzer()
        let health = analyzer.ingest(
            snapshot,
            observedAt: measuredAt
        )
        #expect(health.status == .critical)
        #expect(health.issues == [.stalePlaylistResponse])
        #expect(health.estimatedPlaylistAge == 50)
    }

    @Test("multivariant freshness follows the selected media response")
    func usesSelectedMediaFreshness() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/freshness-master.m3u8")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/freshness-media.m3u8")
        )
        let measuredAt = Date(timeIntervalSince1970: 200)
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=1000
                freshness-media.m3u8
                """,
                headers: ["Age": "99"]
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                segment.ts
                #EXT-X-ENDLIST
                """,
                headers: ["Age": "2"]
            ),
            for: mediaURL
        )
        let client = HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .safeDefaults(),
            now: { measuredAt }
        )

        let snapshot = try await client.snapshot(from: masterURL)

        #expect(snapshot.playlist.sourceURL == mediaURL)
        #expect(snapshot.httpFreshness?.reportedAge == 2)
        #expect(snapshot.httpFreshness?.estimatedPlaylistAge == 2)
    }

    @Test("blocking delta reload reconstructs the complete live window")
    func reconstructsBlockingDeltaReload() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8?token=secret")
        )
        let reloadURL = try #require(
            URL(
                string:
                    "https://media.example/live.m3u8?token=secret&_HLS_msn=12&_HLS_skip=YES"
            )
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24
                #EXTINF:4,
                10.ts
                #EXT-X-DISCONTINUITY
                #EXT-X-GAP
                #EXTINF:4,
                11.ts

                """,
                headers: ["Age": "1"]
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24
                #EXT-X-SKIP:SKIPPED-SEGMENTS=2
                #EXTINF:4,
                12.ts
                #EXT-X-ENDLIST

                """,
                headers: ["Age": "2"]
            ),
            for: reloadURL
        )
        let observer = HLSLiveRequestRecorder()
        let client = HLSLivePlaylistClient(
            session: session,
            requestPolicy: HLSRequestPolicy(
                eventObservers: [observer]
            )
        )

        var snapshots: [HLSLivePlaylistSnapshot] = []
        for try await snapshot in client.snapshots(from: sourceURL) {
            snapshots.append(snapshot)
        }

        #expect(snapshots.count == 2)
        #expect(snapshots.map(\.reloadMode) == [.initial, .blocking])
        #expect(snapshots[0].segments.map(\.sequenceNumber) == [10, 11])
        #expect(snapshots[0].segments[1].beginsDiscontinuity)
        #expect(snapshots[0].segments[1].isGap)
        #expect(snapshots[1].segments.map(\.sequenceNumber) == [10, 11, 12])
        #expect(snapshots[1].generation == 1)
        #expect(snapshots[1].isDeltaUpdate)
        #expect(snapshots[1].isEnded)
        #expect(
            snapshots.map { $0.httpFreshness?.reportedAge }
                == [1, 2]
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, reloadURL]
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().allSatisfy {
                $0.cachePolicy == .reloadIgnoringLocalCacheData
                    && $0.value(
                        forHTTPHeaderField: "Cache-Control"
                    ) == "no-store"
            }
        )
        #expect(
            await observer.purposes()
                == [.entryPlaylist, .livePlaylistReload]
        )
    }

    @Test("partial live edge drives the next msn and part")
    func buildsPartialBlockingPosition() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:20
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24,CAN-SKIP-DATERANGES=YES,PART-HOLD-BACK=2
            #EXT-X-PART-INF:PART-TARGET=1
            #EXTINF:4,
            20.ts
            #EXT-X-PART:DURATION=1,URI="21.0.m4s",INDEPENDENT=YES
            #EXT-X-PART:DURATION=1,URI="21.1.m4s"
            """,
            relativeTo: sourceURL
        )
        let snapshot = HLSLivePlaylistSnapshot(
            playlist: playlist,
            segments: [
                HLSLiveSegment(
                    sequenceNumber: 20,
                    duration: 4,
                    url: sourceURL,
                    byteRange: nil,
                    beginsDiscontinuity: false,
                    isGap: false
                )
            ],
            partialSegments: [
                HLSLivePartialSegment(
                    mediaSequenceNumber: 21,
                    partIndex: 0,
                    duration: 1,
                    url: sourceURL,
                    byteRange: nil,
                    isIndependent: true,
                    isGap: false
                ),
                HLSLivePartialSegment(
                    mediaSequenceNumber: 21,
                    partIndex: 1,
                    duration: 1,
                    url: sourceURL,
                    byteRange: nil,
                    isIndependent: false,
                    isGap: false
                ),
            ],
            dateRanges: [],
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )

        let request = try HLSLiveReloadRequestBuilder.nextRequest(
            after: snapshot,
            settings: HLSLiveReloadPack().resolvedSettings()
        )
        let components = try #require(
            URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )
        )
        let values: [String: String?] = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value)
            }
        )

        #expect(request.usesBlockingReload)
        #expect(request.mode == .blockingPartial)
        #expect(values["_HLS_msn"] == "21")
        #expect(values["_HLS_part"] == "2")
        #expect(values["_HLS_skip"] == "v2")
    }

    @Test("reload settings remain finite and safe to convert to Duration")
    func clampsReloadSettings() {
        let settings = HLSLiveReloadPack(
            minimumPollingInterval: .greatestFiniteMagnitude,
            maximumPollingInterval: .greatestFiniteMagnitude,
            requestTimeout: .greatestFiniteMagnitude
        ).resolvedSettings()

        #expect(settings.minimumPollingInterval == 3_600)
        #expect(settings.maximumPollingInterval == 3_600)
        #expect(settings.requestTimeout == 300)
    }

    @Test("missing delta history falls back to one clean full reload")
    func recoversFromMissingDeltaBase() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/recovery.m3u8")
        )
        let deltaURL = try #require(
            URL(
                string:
                    "https://media.example/recovery.m3u8?_HLS_msn=21&_HLS_skip=YES"
            )
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:20
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24
                #EXTINF:4,
                20.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,CAN-SKIP-UNTIL=24
                #EXT-X-SKIP:SKIPPED-SEGMENTS=2
                #EXTINF:4,
                12.ts
                """
            ),
            for: deltaURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:21
                #EXTINF:4,
                21.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        let client = HLSLivePlaylistClient(session: session)

        var snapshots: [HLSLivePlaylistSnapshot] = []
        for try await snapshot in client.snapshots(from: sourceURL) {
            snapshots.append(snapshot)
        }

        #expect(snapshots.count == 2)
        #expect(
            snapshots.map(\.reloadMode)
                == [.initial, .fullReloadRecovery]
        )
        #expect(snapshots[1].segments.map(\.sequenceNumber) == [21])
        #expect(!snapshots[1].isDeltaUpdate)
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, deltaURL, sourceURL]
        )
    }

    @Test("ended snapshot closes without another reload")
    func endsAfterEndList() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/ended.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                segment.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )

        var count = 0
        for try await snapshot in HLSLivePlaylistClient(
            session: session
        ).snapshots(from: sourceURL) {
            count += 1
            #expect(snapshot.isEnded)
        }

        #expect(count == 1)
        #expect(HLSLiveURLProtocol.capturedRequests().count == 1)
    }

    @Test("multivariant entry selects a variant and exposes renditions")
    func resolvesMultivariantPresentation() async throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let lowURL = try #require(
            URL(string: "https://media.example/low.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,AUTOSELECT=YES
                #EXT-X-STREAM-INF:BANDWIDTH=500000,STABLE-VARIANT-ID="low",AUDIO="audio"
                low.m3u8
                #EXT-X-STREAM-INF:BANDWIDTH=2000000,STABLE-VARIANT-ID="high",AUDIO="audio"
                high.m3u8
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                segment.ts
                #EXT-X-ENDLIST
                """
            ),
            for: lowURL
        )

        let snapshot = try await HLSLivePlaylistClient(
            session: session,
            configuration: .advanced(
                variantSelectionPolicy: .lowestBandwidth
            )
        ).snapshot(from: sourceURL)

        #expect(snapshot.selectedVariant?.stableID == "low")
        #expect(snapshot.selectedVariant?.url == lowURL)
        #expect(snapshot.availableRenditions.map(\.name) == ["Stereo"])
        #expect(snapshot.pathwayID == nil)
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, lowURL]
        )
    }

    @Test("multivariant variables remain available to every reload")
    func preservesMultivariantVariables() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/variables-master.m3u8")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/variables.m3u8")
        )
        let reloadURL = try #require(
            URL(
                string:
                    "https://media.example/variables.m3u8?_HLS_msn=2"
            )
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:8
                #EXT-X-DEFINE:NAME="token",VALUE="parent-value"
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,STABLE-VARIANT-ID="main"
                variables.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-DEFINE:IMPORT="token"
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                1.ts?token={$token}
                """
            ),
            for: mediaURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-DEFINE:IMPORT="token"
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXTINF:4,
                2.ts?token={$token}
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
        )

        var segmentURLs: [URL] = []
        for try await snapshot in HLSLivePlaylistClient(
            session: session
        ).snapshots(from: masterURL) {
            segmentURLs.append(contentsOf: snapshot.segments.map(\.url))
        }

        #expect(
            segmentURLs.map(\.absoluteString)
                == [
                    "https://media.example/1.ts?token=parent-value",
                    "https://media.example/2.ts?token=parent-value",
                ]
        )
    }

    @Test("rendition report supplies a bounded tune-in request")
    func buildsRenditionReportTuneInURL() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/current.m3u8")
        )
        let destinationURL = try #require(
            URL(
                string:
                    "https://media.example/alternate.m3u8?token=secret"
            )
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:40
            #EXTINF:4,
            segment.ts
            #EXT-X-RENDITION-REPORT:URI="alternate.m3u8?token=secret",LAST-MSN=42,LAST-PART=3
            """,
            relativeTo: sourceURL
        )
        let snapshot = HLSLivePlaylistSnapshot(
            playlist: playlist,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )

        let url = try HLSLiveReloadRequestBuilder.tuneInURL(
            for: destinationURL,
            using: snapshot
        )
        let components = try #require(
            URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        )
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value)
            }
        )
        #expect(values["token"] == "secret")
        #expect(values["_HLS_msn"] == "42")
        #expect(values["_HLS_part"] == "3")
    }

    @Test("compatible Content Steering pathway recovers a reload")
    func recoversReloadThroughContentSteering() async throws {
        let steeringObserver =
            HLSLiveContentSteeringRecorder()
        let masterURL = try #require(
            URL(string: "https://media.example/master-steered.m3u8")
        )
        let steeringURL = try #require(
            URL(string: "https://media.example/steering.json")
        )
        let primaryURL = try #require(
            URL(string: "https://media.example/a.m3u8")
        )
        let primaryReloadURL = try #require(
            URL(string: "https://media.example/a.m3u8?_HLS_msn=2")
        )
        let fallbackURL = try #require(
            URL(string: "https://media.example/b.m3u8?_HLS_msn=1")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-CONTENT-STEERING:SERVER-URI="steering.json",PATHWAY-ID="A"
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS="avc1.4d401f",STABLE-VARIANT-ID="main",PATHWAY-ID="A"
                a.m3u8
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS="avc1.4d401f",STABLE-VARIANT-ID="main",PATHWAY-ID="B"
                b.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "VERSION": 1,
                      "TTL": 300,
                      "PATHWAY-PRIORITY": ["A", "B"]
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: steeringURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                1.ts
                #EXT-X-RENDITION-REPORT:URI="b.m3u8",LAST-MSN=1
                """
            ),
            for: primaryURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: fallbackURL
        )

        var snapshots: [HLSLivePlaylistSnapshot] = []
        for try await snapshot in HLSLivePlaylistClient(
            session: session,
            configuration: .advanced(
                variantSelectionPolicy: .highestQuality,
                contentSteering: HLSContentSteeringPack(
                    eventObservers: [steeringObserver]
                )
            )
        ).snapshots(from: masterURL) {
            snapshots.append(snapshot)
        }

        #expect(snapshots.map(\.pathwayID) == ["A", "B"])
        #expect(
            snapshots.map(\.reloadMode)
                == [.initial, .contentSteeringRecovery]
        )
        #expect(snapshots.map(\.isEnded) == [false, true])
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [
                    masterURL,
                    steeringURL,
                    primaryURL,
                    primaryReloadURL,
                    fallbackURL,
                ]
        )
        #expect(
            await steeringObserver.events().contains(
                .pathwayFailed(
                    pathwayID: "A",
                    phase: .mediaPlaylist,
                    resourceIndex: nil,
                    errorCode: .transferFailed
                )
            )
        )
    }

    @Test("penalized live pathway re-enters after cooldown")
    func reentersContentSteeringPathwayAfterCooldown() async throws {
        let observer = HLSLiveContentSteeringRecorder()
        let observationTime = OSAllocatedUnfairLock<Date>(
            initialState: Date(timeIntervalSince1970: 1_000)
        )
        let masterURL = try #require(
            URL(string: "https://media.example/reentry/master.m3u8")
        )
        let steeringURL = try #require(
            URL(string: "https://media.example/reentry/steering.json")
        )
        let primaryURL = try #require(
            URL(string: "https://media.example/reentry/a.m3u8")
        )
        let primaryReloadURL = try #require(
            URL(
                string:
                    "https://media.example/reentry/a.m3u8?_HLS_msn=2"
            )
        )
        let fallbackTuneInURL = try #require(
            URL(
                string:
                    "https://media.example/reentry/b.m3u8?_HLS_msn=1"
            )
        )
        let fallbackReloadURL = try #require(
            URL(string: "https://media.example/reentry/b.m3u8")
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-CONTENT-STEERING:SERVER-URI="steering.json",PATHWAY-ID="A"
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS="avc1.4d401f",STABLE-VARIANT-ID="main",PATHWAY-ID="A"
                a.m3u8
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS="avc1.4d401f",STABLE-VARIANT-ID="main",PATHWAY-ID="B"
                b.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "VERSION": 1,
                      "TTL": 300,
                      "PATHWAY-PRIORITY": ["A", "B"]
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: steeringURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                1.ts
                #EXT-X-RENDITION-REPORT:URI="b.m3u8",LAST-MSN=1
                """
            ),
            for: primaryURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:3
                #EXTINF:4,
                3.ts
                #EXT-X-RENDITION-REPORT:URI="a.m3u8",LAST-MSN=2
                """
            ),
            for: fallbackReloadURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 503,
                data: Data(),
                headers: [:]
            ),
            for: primaryReloadURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXTINF:4,
                2.ts
                #EXT-X-RENDITION-REPORT:URI="a.m3u8",LAST-MSN=2
                """
            ),
            for: fallbackTuneInURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 503,
                data: Data(),
                headers: [:]
            ),
            for: fallbackReloadURL
        )
        HLSLiveURLProtocol.register(
            response(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:4
                #EXTINF:4,
                4.ts
                #EXT-X-ENDLIST
                """
            ),
            for: primaryReloadURL
        )

        let client = HLSLivePlaylistClient(
            resolver: PlaylistResolver(session: session),
            configuration: .advanced(
                reload: HLSLiveReloadPack(
                    minimumPollingInterval: 0.05,
                    maximumPollingInterval: 0.05
                ),
                variantSelectionPolicy: .highestQuality,
                contentSteering: HLSContentSteeringPack(
                    healthPolicy: HLSContentSteeringHealthPolicy(
                        recoveryCooldown: .seconds(1)
                    ),
                    eventObservers: [observer]
                )
            ),
            sleep: { _ in
                observationTime.withLock {
                    $0.addTimeInterval(2)
                }
            },
            now: { observationTime.withLock { $0 } }
        )
        var snapshots: [HLSLivePlaylistSnapshot] = []
        for try await snapshot in client.snapshots(from: masterURL) {
            snapshots.append(snapshot)
        }

        #expect(snapshots.map(\.pathwayID) == ["A", "B", "B", "A"])
        #expect(
            snapshots.map(\.reloadMode)
                == [
                    .initial,
                    .contentSteeringRecovery,
                    .polling,
                    .contentSteeringRecovery,
                ]
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [
                    masterURL,
                    steeringURL,
                    primaryURL,
                    primaryReloadURL,
                    fallbackTuneInURL,
                    fallbackReloadURL,
                    fallbackReloadURL,
                    primaryReloadURL,
                ]
        )
        let events = await observer.events()
        #expect(
            events.contains(
                .pathwaySelectionChanged(
                    fromPathwayID: "B",
                    toPathwayID: "A",
                    reason: .cooldownRecovery
                )
            )
        )
        let recoveredSnapshots: [HLSContentSteeringPathwaySnapshot] =
            events.compactMap { event in
                guard case .pathwayHealthChanged(let snapshot) = event,
                    snapshot.pathwayID == "A",
                    snapshot.selectionCounts[.cooldownRecovery] == 1
                else {
                    return nil
                }
                return snapshot
            }
        let recoveredHealth = recoveredSnapshots.last
        #expect(recoveredHealth?.availability == .available)
        #expect(recoveredHealth?.failureCount == 1)
        #expect(recoveredHealth?.selectionCounts[.cooldownRecovery] == 1)
        let fallbackHealth: HLSContentSteeringPathwaySnapshot? =
            events.compactMap { event in
                guard case .pathwayHealthChanged(let snapshot) = event,
                    snapshot.pathwayID == "B"
                else {
                    return nil
                }
                return snapshot
            }.last
        #expect(fallbackHealth?.attemptCount == 3)
        #expect(fallbackHealth?.successCount == 2)
        #expect(fallbackHealth?.failureCount == 1)
        #expect(fallbackHealth?.successRate == 2.0 / 3.0)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSLiveURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(
        _ playlist: String,
        headers: [String: String] = [:]
    ) -> HLSLiveURLProtocol.Response {
        var responseHeaders = headers
        responseHeaders["Content-Type"] =
            "application/vnd.apple.mpegurl"
        return HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: Data(playlist.utf8),
            headers: responseHeaders
        )
    }
}

private actor HLSLiveContentSteeringRecorder:
    HLSContentSteeringEventObserving
{
    private var recordedEvents: [HLSContentSteeringEvent] = []

    func contentSteeringDidEmit(
        _ event: HLSContentSteeringEvent
    ) {
        recordedEvents.append(event)
    }

    func events() -> [HLSContentSteeringEvent] {
        recordedEvents
    }
}

private actor HLSLiveRequestRecorder: HLSRequestEventObserving {
    private var contexts: [HLSRequestContext] = []

    func hlsRequestDidEmit(_ event: HLSRequestEvent) {
        guard case .requestStarted(let context) = event else {
            return
        }
        contexts.append(context)
    }

    func purposes() -> [HLSRequestPurpose] {
        contexts.map(\.purpose)
    }
}
