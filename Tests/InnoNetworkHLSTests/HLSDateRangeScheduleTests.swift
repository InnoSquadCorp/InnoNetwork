import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("Date Range preload metadata is typed and VOD preloading is disabled")
    func parsesDateRangePreloadMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/index.m3u8")
        )
        let live = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:6,
            segment.ts
            #EXT-X-DATERANGE:ID="preload",CLASS="com.apple.hls.preload",START-DATE="2026-08-06T12:00:00Z",DURATION=10,X-URI="schedule.json",X-TARGET-ID="target",X-TARGET-CLASS="com.apple.hls.daterange-schedule",X-DURATION-AT-JOIN=3
            """,
            relativeTo: sourceURL
        )
        let preload = try #require(live.dateRanges.first?.preload)

        #expect(preload.isEligible)
        #expect(preload.targetID == "target")
        #expect(
            preload.targetClass
                == "com.apple.hls.daterange-schedule"
        )
        #expect(preload.durationAtJoin == 3)
        #expect(
            preload.resource.url.absoluteString
                == "https://media.example/live/schedule.json"
        )

        let vod = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:6,
            segment.ts
            #EXT-X-ENDLIST
            #EXT-X-DATERANGE:ID="preload",CLASS="com.apple.hls.preload",START-DATE="2026-08-06T12:00:00Z",DURATION=10,X-URI="schedule.json",X-TARGET-ID="target",X-TARGET-CLASS="com.apple.hls.daterange-schedule"
            """,
            relativeTo: sourceURL
        )

        #expect(vod.dateRanges.first?.preload?.isEligible == false)
    }

    @Test(
        "invalid Date Range preload contracts are rejected",
        arguments: [
            #"DURATION=10,X-URI="resource.json",X-TARGET-ID="target""#,
            #"DURATION=10,X-URI="resource.json",X-TARGET-CLASS="target""#,
            #"X-URI="resource.json",X-TARGET-ID="target",X-TARGET-CLASS="target""#,
            #"DURATION=10,CUE="PRE",X-URI="resource.json",X-TARGET-ID="target",X-TARGET-CLASS="target""#,
            #"DURATION=10,END-ON-NEXT=YES,X-URI="resource.json",X-TARGET-ID="target",X-TARGET-CLASS="target""#,
            #"DURATION=10,X-URI="resource.json",X-TARGET-ID="target",X-TARGET-CLASS="target",X-DURATION-AT-JOIN=0"#,
        ]
    )
    func rejectsInvalidDateRangePreload(_ attributes: String) throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/live/index.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
                #EXTINF:6,
                segment.ts
                #EXT-X-DATERANGE:ID="preload",CLASS="com.apple.hls.preload",START-DATE="2026-08-06T12:00:00Z",\(attributes)
                """,
                relativeTo: sourceURL
            )
        }
    }

    @Test("Date Range schedules resolve nested entries within parent bounds")
    func resolvesNestedDateRangeSchedules() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/live/index.m3u8")
        )
        let rootURL = try #require(
            URL(
                string:
                    "https://media.example/live/root.json?token=secret&_HLS_start_offset=7.5"
            )
        )
        let nestedURL = try #require(
            URL(string: "https://media.example/live/nested.json")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:6,
            segment.ts
            #EXT-X-DATERANGE:ID="root",CLASS="com.apple.hls.daterange-schedule",START-DATE="2026-08-06T12:00:00Z",DURATION=30,X-URI="root.json?token=secret",CUE="PRE"
            """,
            relativeTo: playlistURL
        )
        let session = makeDateRangeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "ad",
                          "CLASS": "com.apple.hls.interstitial",
                          "X-SCHEDULE-OFFSET": 5,
                          "DURATION": 4,
                          "CUE": "PRE",
                          "X-ASSET-URI": "https://ads.example/ad.m3u8"
                        },
                        {
                          "ID": "nested",
                          "CLASS": "com.apple.hls.daterange-schedule",
                          "X-SCHEDULE-OFFSET": 10,
                          "DURATION": 25,
                          "CUE": "PRE",
                          "X-URI": "nested.json"
                        },
                        {
                          "ID": "outside",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 40,
                          "DURATION": 1
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: rootURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "nested-ad",
                          "CLASS": "com.apple.hls.interstitial",
                          "X-SCHEDULE-OFFSET": 2,
                          "DURATION": 3,
                          "CUE": "PRE",
                          "X-ASSET-URI": "https://ads.example/nested.m3u8"
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: nestedURL
        )

        let schedule = try await HLSExternalResourceResolver(
            session: session
        ).resolveDateRangeSchedule(
            try #require(playlist.dateRanges.first),
            startOffset: 7.5,
            occupiedDateRangeIDs: ["playlist-range"]
        )

        #expect(schedule.entries.count == 2)
        #expect(schedule.entries[0].dateRange.id == "ad")
        #expect(
            schedule.entries[0].dateRange.startDate
                .timeIntervalSince(schedule.source.startDate) == 5
        )
        let nested = try #require(
            schedule.entries[1].nestedSchedule
        )
        #expect(nested.entries.count == 1)
        #expect(nested.entries[0].dateRange.id == "nested-ad")
        #expect(
            HLSURLProtocol.capturedRequests()
                .compactMap(\.url) == [rootURL, nestedURL]
        )
    }

    @Test("preloaded Date Range resources are reused only by their target")
    func reusesMatchingDateRangePreload() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/live/index.m3u8")
        )
        let resourceURL = try #require(
            URL(string: "https://media.example/live/schedule.json")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-PROGRAM-DATE-TIME:2026-08-06T12:00:00Z
            #EXTINF:6,
            segment.ts
            #EXT-X-DATERANGE:ID="preload",CLASS="com.apple.hls.preload",START-DATE="2026-08-06T12:00:00Z",DURATION=10,X-URI="schedule.json",X-TARGET-ID="target",X-TARGET-CLASS="com.apple.hls.daterange-schedule"
            #EXT-X-DATERANGE:ID="target",CLASS="com.apple.hls.daterange-schedule",START-DATE="2026-08-06T12:00:10Z",DURATION=10,X-URI="schedule.json"
            """,
            relativeTo: playlistURL
        )
        let data = Data(
            """
            {
              "DATERANGES": [
                {
                  "ID": "ad",
                  "CLASS": "com.apple.hls.interstitial",
                  "X-SCHEDULE-OFFSET": 1,
                  "DURATION": 2,
                  "X-ASSET-URI": "https://ads.example/ad.m3u8"
                }
              ]
            }
            """.utf8
        )
        let session = makeDateRangeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: data,
                headers: ["Content-Type": "application/json"]
            ),
            for: resourceURL
        )
        let observer = HLSDateRangeRequestRecorder()
        let resolver = HLSExternalResourceResolver(
            session: session,
            requestPolicy: HLSRequestPolicy(
                eventObservers: [observer]
            )
        )

        let preloaded = try await resolver.preloadDateRangeResource(
            try #require(playlist.dateRanges.first)
        )
        let schedule = try await resolver.resolveDateRangeSchedule(
            try #require(playlist.dateRanges.last),
            preloadedResource: preloaded
        )

        #expect(schedule.entries.map(\.dateRange.id) == ["ad"])
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [resourceURL]
        )
        #expect(
            HLSURLProtocol.capturedRequests().first?
                .value(forHTTPHeaderField: "Accept") == "*/*"
        )
        #expect(
            await observer.purposes()
                == [.dateRangePreloadResource]
        )
    }

    @Test("Date Range schedule cycles and duplicate IDs are rejected")
    func rejectsDateRangeScheduleCyclesAndDuplicateIDs() async throws {
        let scheduleURL = try #require(
            URL(string: "https://media.example/schedule.json")
        )
        let parent = HLSDateRange(
            id: "root",
            className: "com.apple.hls.daterange-schedule",
            startDate: Date(timeIntervalSince1970: 1_775_649_600),
            duration: 30,
            externalResource: HLSDateRangeResource(url: scheduleURL)
        )
        let session = makeDateRangeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "nested",
                          "CLASS": "com.apple.hls.daterange-schedule",
                          "X-SCHEDULE-OFFSET": 1,
                          "DURATION": 10,
                          "X-URI": "schedule.json"
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: [:]
            ),
            for: scheduleURL
        )

        await #expect(
            throws: HLSExternalResourceError.dateRangeScheduleCycle
        ) {
            try await HLSExternalResourceResolver(
                session: session
            ).resolveDateRangeSchedule(parent)
        }

        HLSURLProtocol.reset()
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "duplicate",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 1,
                          "DURATION": 1
                        },
                        {
                          "ID": "duplicate",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 2,
                          "DURATION": 1
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: [:]
            ),
            for: scheduleURL
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .duplicateScheduledDateRangeIdentifier
        ) {
            try await HLSExternalResourceResolver(
                session: session
            ).resolveDateRangeSchedule(parent)
        }
    }

    @Test("Date Range schedule depth, count, and start offset are bounded")
    func boundsDateRangeScheduleResolution() async throws {
        let rootURL = try #require(
            URL(string: "https://media.example/root.json")
        )
        let nestedURL = try #require(
            URL(string: "https://media.example/nested.json")
        )
        let parent = HLSDateRange(
            id: "root",
            className: "com.apple.hls.daterange-schedule",
            startDate: Date(timeIntervalSinceReferenceDate: 0),
            duration: 30,
            externalResource: HLSDateRangeResource(url: rootURL)
        )
        let session = makeDateRangeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }

        await #expect(
            throws:
                HLSExternalResourceError
                .invalidDateRangeScheduleStartOffset
        ) {
            try await HLSExternalResourceResolver(
                session: session
            ).resolveDateRangeSchedule(
                parent,
                startOffset: -.infinity
            )
        }

        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "nested",
                          "CLASS": "com.apple.hls.daterange-schedule",
                          "X-SCHEDULE-OFFSET": 1,
                          "DURATION": 10,
                          "X-URI": "nested.json"
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: [:]
            ),
            for: rootURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "too-deep",
                          "CLASS": "com.apple.hls.daterange-schedule",
                          "X-SCHEDULE-OFFSET": 1,
                          "DURATION": 5,
                          "X-URI": "deep.json"
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: [:]
            ),
            for: nestedURL
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .dateRangeScheduleDepthExceeded(limit: 2)
        ) {
            try await HLSExternalResourceResolver(
                session: session,
                configuration: HLSExternalResourcePack(
                    maximumDateRangeScheduleDepth: 2
                )
            ).resolveDateRangeSchedule(parent)
        }

        HLSURLProtocol.reset()
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "one",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 1,
                          "DURATION": 1
                        },
                        {
                          "ID": "outside",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 40,
                          "DURATION": 1
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: [:]
            ),
            for: rootURL
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .tooManyScheduledDateRanges(limit: 1)
        ) {
            try await HLSExternalResourceResolver(
                session: session,
                configuration: HLSExternalResourcePack(
                    maximumScheduledDateRangeCount: 1
                )
            ).resolveDateRangeSchedule(parent)
        }
    }

    @Test("Date Range schedule members retain playlist timeline rules")
    func validatesScheduledDateRangeTimelines() async throws {
        let scheduleURL = try #require(
            URL(string: "https://media.example/schedule.json")
        )
        let parent = HLSDateRange(
            id: "root",
            className: "com.apple.hls.daterange-schedule",
            startDate: Date(timeIntervalSinceReferenceDate: 0),
            duration: 30,
            externalResource: HLSDateRangeResource(url: scheduleURL)
        )
        let session = makeDateRangeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "overlap",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 3,
                          "DURATION": 10
                        },
                        {
                          "ID": "next",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 5,
                          "END-ON-NEXT": "YES"
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: [:]
            ),
            for: scheduleURL
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .invalidDateRangeSchedule
        ) {
            try await HLSExternalResourceResolver(
                session: session
            ).resolveDateRangeSchedule(parent)
        }
    }

    @Test("POST schedules reject members that also carry PRE")
    func rejectsPreMembersInPostSchedules() async throws {
        let scheduleURL = try #require(
            URL(string: "https://media.example/schedule.json")
        )
        let parent = HLSDateRange(
            id: "root",
            className: "com.apple.hls.daterange-schedule",
            startDate: Date(timeIntervalSinceReferenceDate: 0),
            duration: 30,
            cues: [.pre, .post],
            externalResource: HLSDateRangeResource(url: scheduleURL)
        )
        let session = makeDateRangeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "DATERANGES": [
                        {
                          "ID": "mixed-cue",
                          "CLASS": "chapter",
                          "X-SCHEDULE-OFFSET": 1,
                          "DURATION": 1,
                          "CUE": "PRE,POST"
                        }
                      ]
                    }
                    """.utf8
                ),
                headers: [:]
            ),
            for: scheduleURL
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .invalidDateRangeSchedule
        ) {
            try await HLSExternalResourceResolver(
                session: session
            ).resolveDateRangeSchedule(parent)
        }
    }

    private func makeDateRangeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor HLSDateRangeRequestRecorder: HLSRequestEventObserving {
    private var recordedPurposes: [HLSRequestPurpose] = []

    func hlsRequestDidEmit(_ event: HLSRequestEvent) {
        guard case .requestStarted(let context) = event else {
            return
        }
        recordedPurposes.append(context.purpose)
    }

    func purposes() -> [HLSRequestPurpose] {
        recordedPurposes
    }
}
