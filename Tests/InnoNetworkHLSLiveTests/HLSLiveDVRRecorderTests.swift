import CommonCrypto
import Foundation
import InnoNetworkHLS
import Testing

@testable import InnoNetworkHLSLive

extension HLSLivePlaylistClientTests {
    @Test("limit packs normalize unsafe values")
    func limitNormalization() {
        let limits = HLSLiveDVRLimitPack(
            maximumDuration: .nan,
            maximumSegmentCount: -1,
            maximumMediaResourceBytes: -1,
            maximumTotalMediaBytes: -1,
            requestTimeout: .infinity
        )

        #expect(limits.maximumDuration == 30 * 60)
        #expect(limits.maximumSegmentCount == 1)
        #expect(limits.maximumMediaResourceBytes == 1)
        #expect(limits.maximumTotalMediaBytes == 1)
        #expect(limits.requestTimeout == 60)
        #expect(limits.retentionPolicy == .stopAtLimit)

        let rollingLimits = HLSLiveDVRLimitPack(
            retentionPolicy: .rollingWindow
        )
        #expect(rollingLimits.retentionPolicy == .rollingWindow)

        let parts = HLSLiveDVRPartPack(
            policy: .independent,
            maximumStagedPartCount: -1,
            maximumStagedPartBytes: -1
        )
        #expect(parts.policy == .independent)
        #expect(parts.maximumStagedPartCount == 1)
        #expect(parts.maximumStagedPartBytes == 1)

        let preloading = HLSLiveDVRPreloadPack(
            policy: .unencryptedMedia,
            maximumResourceBytes: -1,
            maximumTotalBytes: .max
        )
        #expect(preloading.policy == .unencryptedMedia)
        #expect(preloading.maximumResourceBytes == 1)
        #expect(preloading.maximumTotalBytes == 256 * 1_024 * 1_024)
    }

    @Test("current live window commits a URL-free local VOD playlist")
    func recordsCurrentWindow() async throws {
        let sourceURL = try url("https://media.example/current.m3u8")
        let firstURL = try url("https://media.example/10.ts?token=one")
        let secondURL = try url("https://media.example/11.ts?token=two")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                10.ts?token=one
                #EXT-X-DISCONTINUITY
                #EXTINF:3.5,
                11.ts?token=two
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 2)
        #expect(receipt.recordedDuration == 7.5)
        #expect(receipt.mediaByteCount == 11)
        #expect(
            receipt.preloadStatistics
                == HLSLiveDVRPreloadStatistics()
        )
        #expect(receipt.firstMediaSequence == 10)
        #expect(receipt.lastMediaSequence == 11)
        #expect(
            receipt.playbackSource.packageDirectoryURL
                == receipt.directoryURL
        )
        #expect(
            receipt.playbackSource.entryPlaylistURL
                == receipt.entryPlaylistURL
        )
        #expect(
            FileManager.default.fileExists(
                atPath: receipt.playlistURL.path
            )
        )
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:10"))
        #expect(playlist.contains("#EXT-X-DISCONTINUITY"))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        #expect(!playlist.contains("media.example"))
        #expect(!playlist.contains("token="))
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, firstURL, secondURL]
        )
    }

    @Test("declared gaps preserve timeline without requesting missing media")
    func recordsDeclaredGapWithoutMediaRequest() async throws {
        let sourceURL = try url("https://media.example/gap.m3u8")
        let firstURL = try url("https://media.example/gap-10.ts")
        let gapURL = try url("https://media.example/gap-11.ts")
        let thirdURL = try url("https://media.example/gap-12.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                gap-10.ts
                #EXT-X-GAP
                #EXTINF:4,
                gap-11.ts
                #EXTINF:4,
                gap-12.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("third".utf8)),
            for: thirdURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 3)
        #expect(receipt.gapCount == 1)
        #expect(receipt.recordedDuration == 12)
        #expect(receipt.mediaByteCount == 10)
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(
            playlist.contains(
                "#EXT-X-GAP\n#EXTINF:4.0,\nresources/gap-00001.ts"
            )
        )
        #expect(!playlist.contains("media.example"))
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL.appendingPathComponent(
                    "resources/gap-00001.ts"
                ).path
            )
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, firstURL, thirdURL]
        )
        #expect(
            !HLSLiveURLProtocol.capturedRequests().contains { request in
                request.url == gapURL
            })
    }

    @Test("recording handle stops and commits idempotently")
    func stopsAndCommitsRecordingHandle() async throws {
        let sourceURL = try url("https://media.example/controlled.m3u8")
        let segmentURL = try url("https://media.example/controlled.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                controlled.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("segment".utf8)),
            for: segmentURL
        )

        let recording = recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress(let progress) = try await events.next() else {
            Issue.record("Expected retained-segment progress")
            return
        }
        #expect(progress.segmentCount == 1)
        #expect(
            progress.preloadStatistics
                == HLSLiveDVRPreloadStatistics()
        )

        let receipt = try await recording.stopAndCommit()
        let repeatedReceipt = try await recording.stopAndCommit()
        #expect(receipt == repeatedReceipt)
        #expect(receipt.segmentCount == 1)
        #expect(receipt.firstMediaSequence == 10)
        #expect(receipt.lastMediaSequence == 10)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
        #expect(try await events.next() == .completed(receipt))
        #expect(try await events.next() == nil)
    }

    @Test("recording handle cancels and discards idempotently")
    func cancelsAndDiscardsRecordingHandle() async throws {
        let sourceURL = try url("https://media.example/discard.m3u8")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                """
            ),
            for: sourceURL
        )

        let recording = recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        await recording.cancelAndDiscard()
        await recording.cancelAndDiscard()

        await #expect(throws: CancellationError.self) {
            try await recording.stopAndCommit()
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
        var events = recording.events.makeAsyncIterator()
        #expect(try await events.next() == nil)
    }

    @Test("playback snapshot freezes a coherent package while recording continues")
    func capturesPlaybackSnapshotWhileRecordingContinues() async throws {
        let sourceURL = try url("https://media.example/timeshift.m3u8")
        let firstURL = try url("https://media.example/timeshift-10.ts")
        let secondURL = try url("https://media.example/timeshift-11.ts")
        let fixture = try makeFixture()
        let snapshotURL = fixture.rootURL.appendingPathComponent(
            "timeshift-snapshot",
            isDirectory: true
        )
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                timeshift-10.ts
                #EXTINF:4,
                timeshift-11.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8), delay: 0.1),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8), delay: 0.5),
            for: secondURL
        )

        let recording = recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        let snapshot = try await recording.capturePlaybackSnapshot(
            to: snapshotURL
        )

        #expect(snapshot.segmentCount == 1)
        #expect(snapshot.firstMediaSequence == 10)
        #expect(snapshot.lastMediaSequence == 10)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
        let snapshotPlaylist = try String(
            contentsOf: snapshot.playlistURL,
            encoding: .utf8
        )
        #expect(snapshotPlaylist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(snapshotPlaylist.contains("#EXT-X-ENDLIST"))
        #expect(!snapshotPlaylist.contains("media.example"))
        #expect(
            try Data(
                contentsOf: snapshot.directoryURL.appendingPathComponent(
                    "resources/00000.ts"
                )
            ) == Data("first".utf8)
        )

        let finalReceipt = try await recording.stopAndCommit()
        #expect(finalReceipt.segmentCount == 2)
        #expect(
            FileManager.default.fileExists(
                atPath: snapshot.playlistURL.path
            )
        )
        #expect(
            try Data(
                contentsOf: snapshot.directoryURL.appendingPathComponent(
                    "resources/00000.ts"
                )
            ) == Data("first".utf8)
        )
    }

    @Test("playback snapshot survives later rolling eviction")
    func playbackSnapshotSurvivesRollingEviction() async throws {
        let sourceURL = try url(
            "https://media.example/timeshift-rolling.m3u8"
        )
        let segmentURLs = try (10...12).map {
            try url("https://media.example/timeshift-rolling-\($0).ts")
        }
        let fixture = try makeFixture()
        let snapshotURL = fixture.rootURL.appendingPathComponent(
            "rolling-snapshot",
            isDirectory: true
        )
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:1,
                timeshift-rolling-10.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:1,
                timeshift-rolling-10.ts
                #EXTINF:1,
                timeshift-rolling-11.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:1,
                timeshift-rolling-10.ts
                #EXTINF:1,
                timeshift-rolling-11.ts
                #EXTINF:1,
                timeshift-rolling-12.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        for (index, segmentURL) in segmentURLs.enumerated() {
            HLSLiveURLProtocol.register(
                mediaResponse(
                    Data("media-\(index + 10)".utf8),
                    delay: index == 0 ? 0.15 : 0.05
                ),
                for: segmentURL
            )
        }

        let recording = rollingRecorder(
            session: fixture.session,
            maximumSegmentCount: 2
        ).startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        let completion = Task<HLSLiveDVRReceipt, Error> {
            for try await event in recording.events {
                if case .completed(let receipt) = event {
                    return receipt
                }
            }
            throw HLSLiveDVRError.playbackSnapshotUnavailable
        }
        let snapshot = try await recording.capturePlaybackSnapshot(
            to: snapshotURL
        )
        let finalReceipt = try await completion.value

        #expect(snapshot.segmentCount == 1)
        #expect(snapshot.firstMediaSequence == 10)
        #expect(snapshot.lastMediaSequence == 10)
        #expect(finalReceipt.segmentCount == 2)
        #expect(finalReceipt.firstMediaSequence == 11)
        #expect(finalReceipt.lastMediaSequence == 12)
        #expect(
            finalReceipt.retentionStatistics.evictedPrimarySegmentCount == 1
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: finalReceipt.directoryURL.appendingPathComponent(
                    "resources/sequence-10.ts"
                ).path
            )
        )
        #expect(
            try Data(
                contentsOf: snapshot.directoryURL.appendingPathComponent(
                    "resources/sequence-10.ts"
                )
            ) == Data("media-10".utf8)
        )
    }

    @Test("snapshot failure and cancellation stay isolated from recording")
    func isolatesPlaybackSnapshotFailureAndCancellation() async throws {
        let sourceURL = try url("https://media.example/timeshift-failure.m3u8")
        let segmentURL = try url("https://media.example/timeshift-failure.ts")
        let fixture = try makeFixture()
        let existingSnapshotURL = fixture.rootURL.appendingPathComponent(
            "existing-snapshot",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: existingSnapshotURL,
            withIntermediateDirectories: false
        )
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                timeshift-failure.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("segment".utf8), delay: 0.1),
            for: segmentURL
        )

        let recording = recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        await #expect(throws: HLSLiveDVRError.destinationAlreadyExists) {
            try await recording.capturePlaybackSnapshot(
                to: existingSnapshotURL
            )
        }

        let cancelledSnapshotURL = fixture.rootURL.appendingPathComponent(
            "cancelled-snapshot",
            isDirectory: true
        )
        let cancelledSnapshot = Task {
            try await recording.capturePlaybackSnapshot(
                to: cancelledSnapshotURL
            )
        }
        await Task.yield()
        cancelledSnapshot.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledSnapshot.value
        }

        let receipt = try await recording.stopAndCommit()
        #expect(receipt.segmentCount == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: cancelledSnapshotURL.path
            )
        )
        await #expect(throws: HLSLiveDVRError.playbackSnapshotUnavailable) {
            try await recording.capturePlaybackSnapshot(
                to: cancelledSnapshotURL
            )
        }
    }

    @Test("concurrent snapshot requests share one coherent boundary")
    func capturesConcurrentPlaybackSnapshotsAtOneBoundary() async throws {
        let sourceURL = try url("https://media.example/timeshift-shared.m3u8")
        let firstURL = try url("https://media.example/timeshift-shared-10.ts")
        let secondURL = try url("https://media.example/timeshift-shared-11.ts")
        let fixture = try makeFixture()
        let firstSnapshotURL = fixture.rootURL.appendingPathComponent(
            "first-snapshot",
            isDirectory: true
        )
        let secondSnapshotURL = fixture.rootURL.appendingPathComponent(
            "second-snapshot",
            isDirectory: true
        )
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                timeshift-shared-10.ts
                #EXTINF:4,
                timeshift-shared-11.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8), delay: 0.15),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8), delay: 0.5),
            for: secondURL
        )

        let recording = recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        async let firstSnapshot = recording.capturePlaybackSnapshot(
            to: firstSnapshotURL
        )
        async let secondSnapshot = recording.capturePlaybackSnapshot(
            to: secondSnapshotURL
        )
        let (first, second) = try await (firstSnapshot, secondSnapshot)

        #expect(first.segmentCount == 1)
        #expect(second.segmentCount == 1)
        #expect(first.firstMediaSequence == second.firstMediaSequence)
        #expect(first.lastMediaSequence == second.lastMediaSequence)
        #expect(
            try Data(contentsOf: first.playlistURL)
                == Data(contentsOf: second.playlistURL)
        )
        _ = try await recording.stopAndCommit()
    }

    @Test("playback snapshot requests are bounded and release cancelled slots")
    func boundsPlaybackSnapshotRequests() async throws {
        let control = HLSLiveDVRRecordingControl()
        var requests: [HLSLiveDVRPlaybackSnapshotRequest] = []
        for index in 0..<8 {
            let request = HLSLiveDVRPlaybackSnapshotRequest(
                destinationDirectoryURL:
                    FileManager.default.temporaryDirectory
                    .appendingPathComponent("snapshot-\(index)")
            )
            try await control.registerPlaybackSnapshotRequest(request)
            requests.append(request)
        }
        let rejectedRequest = HLSLiveDVRPlaybackSnapshotRequest(
            destinationDirectoryURL:
                FileManager.default.temporaryDirectory
                .appendingPathComponent("snapshot-rejected")
        )
        await #expect(
            throws: HLSLiveDVRError.playbackSnapshotRequestLimitExceeded(
                limit: 8
            )
        ) {
            try await control.registerPlaybackSnapshotRequest(rejectedRequest)
        }
        await requests[0].cancel()
        await control.cancelPlaybackSnapshotRequest(requests[0])
        let replacement = HLSLiveDVRPlaybackSnapshotRequest(
            destinationDirectoryURL:
                FileManager.default.temporaryDirectory
                .appendingPathComponent("snapshot-replacement")
        )
        try await control.registerPlaybackSnapshotRequest(replacement)

        let activeRequests = await control.takePlaybackSnapshotRequests()
        #expect(activeRequests.count == 8)
        await #expect(
            throws: HLSLiveDVRError.playbackSnapshotRequestLimitExceeded(
                limit: 8
            )
        ) {
            try await control.registerPlaybackSnapshotRequest(rejectedRequest)
        }

        await activeRequests[0].cancel()
        await control.cancelPlaybackSnapshotRequest(activeRequests[0])
        await #expect(
            throws: HLSLiveDVRError.playbackSnapshotRequestLimitExceeded(
                limit: 8
            )
        ) {
            try await control.registerPlaybackSnapshotRequest(rejectedRequest)
        }
        await control.completePlaybackSnapshotRequest(activeRequests[0])
        try await control.registerPlaybackSnapshotRequest(rejectedRequest)
        for request in activeRequests.dropFirst() {
            await request.fail(.playbackSnapshotUnavailable)
            await control.completePlaybackSnapshotRequest(request)
        }
        await control.finishPlaybackSnapshotRequests()

        await #expect(throws: CancellationError.self) {
            try await requests[0].value()
        }
        await #expect(throws: HLSLiveDVRError.playbackSnapshotUnavailable) {
            try await replacement.value()
        }
        await #expect(throws: HLSLiveDVRError.playbackSnapshotUnavailable) {
            try await rejectedRequest.value()
        }
        await #expect(throws: HLSLiveDVRError.playbackSnapshotUnavailable) {
            try await control.registerPlaybackSnapshotRequest(
                HLSLiveDVRPlaybackSnapshotRequest(
                    destinationDirectoryURL:
                        FileManager.default.temporaryDirectory
                        .appendingPathComponent("snapshot-after-finish")
                )
            )
        }
    }

    @Test("completed atomic snapshot publication wins a late cancellation")
    func snapshotPublicationWinsLateCancellation() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-snapshot")
        let receipt = HLSLiveDVRReceipt(
            directoryURL: directoryURL,
            playlistURL: directoryURL.appendingPathComponent("index.m3u8"),
            entryPlaylistURL: directoryURL.appendingPathComponent(
                "index.m3u8"
            ),
            tracks: [],
            segmentCount: 1,
            recordedDuration: 4,
            mediaByteCount: 7,
            firstMediaSequence: 10,
            lastMediaSequence: 10
        )
        let request = HLSLiveDVRPlaybackSnapshotRequest(
            destinationDirectoryURL: directoryURL
        )
        let operation = Task<HLSLiveDVRReceipt, Error> {
            receipt
        }
        #expect(await request.installOperationTask(operation))
        _ = try await operation.value

        await request.cancel()

        #expect(try await request.value() == receipt)
    }

    @Test("recovery discard respects the active destination lease")
    func recoveryDiscardRespectsDestinationLease() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        let recorder = recorder(
            session: fixture.session,
            startPosition: .currentWindow
        )
        let lease = try await HLSDestinationLease.acquire(
            for: fixture.destinationURL
        )

        await #expect(throws: HLSLiveDVRError.destinationInUse) {
            try await recorder.discardRecovery(
                for: fixture.destinationURL
            )
        }

        await lease.release()
    }

    @Test("resumable DVR rotates signed URLs without redownloading media")
    func resumesWithFreshSignedURL() async throws {
        let sourceURL = try url(
            "https://media.example/recovery.m3u8?token=expired"
        )
        let resumedSourceURL = try url(
            "https://media.example/recovery.m3u8?token=fresh"
        )
        let firstSegmentURL = try url(
            "https://media.example/recovery-10.ts"
        )
        let secondSegmentURL = try url(
            "https://media.example/recovery-11.ts"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        let recorder = try await interruptedRecoveryRecorder(
            sourceURL: sourceURL,
            segmentURL: firstSegmentURL,
            fixture: fixture
        )
        let recoveryRoot = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        ).rootURL
        let checkpointData = try Data(
            contentsOf: recoveryRoot.appendingPathComponent(
                "checkpoint.json"
            )
        )
        let checkpointText = try #require(
            String(data: checkpointData, encoding: .utf8)
        )
        #expect(checkpointText.contains("sourceURLSHA256"))
        #expect(checkpointText.contains("contentSHA256"))
        #expect(!checkpointText.contains("https://"))
        #expect(!checkpointText.contains("media.example"))
        #expect(!checkpointText.contains("token"))

        let staleDirectory =
            recoveryRoot
            .appendingPathComponent("package", isDirectory: true)
            .appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staleDirectory,
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(
            to: staleDirectory.appendingPathComponent("stale.part")
        )

        await #expect(throws: HLSLiveDVRError.recoveryAlreadyExists) {
            try await recorder.record(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                recovery-10.ts
                #EXTINF:4,
                recovery-11.ts
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondSegmentURL
        )

        let receipt = try await recorder.resume(
            from: resumedSourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 2)
        #expect(receipt.firstMediaSequence == 10)
        #expect(receipt.lastMediaSequence == 11)
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                .count { $0 == firstSegmentURL } == 1
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                .count { $0 == secondSegmentURL } == 1
        )
        #expect(
            !FileManager.default.fileExists(atPath: recoveryRoot.path)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL
                    .appendingPathComponent("partial").path
            )
        )
    }

    @Test("resumable DVR checkpoints gaps and rejects retroactive availability")
    func resumesCheckpointedGap() async throws {
        let sourceURL = try url(
            "https://media.example/gap-recovery.m3u8?mode=initial"
        )
        let mismatchedURL = try url(
            "https://media.example/gap-recovery.m3u8?mode=mismatch"
        )
        let resumedURL = try url(
            "https://media.example/gap-recovery.m3u8?mode=resumed"
        )
        let firstSegmentURL = try url(
            "https://media.example/gap-recovery-10.ts"
        )
        let gapSegmentURL = try url(
            "https://media.example/gap-recovery-11.ts"
        )
        let thirdSegmentURL = try url(
            "https://media.example/gap-recovery-12.ts"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                gap-recovery-10.ts
                #EXT-X-GAP
                #EXTINF:4,
                gap-recovery-11.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstSegmentURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress = try await events.next(),
            case .progress(let gapProgress) = try await events.next()
        else {
            Issue.record("Expected media and gap checkpoints")
            return
        }
        #expect(gapProgress.segmentCount == 2)
        #expect(gapProgress.gapCount == 1)
        await recording.interrupt()

        let checkpointURL = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        ).rootURL.appendingPathComponent("checkpoint.json")
        let checkpoint = try JSONDecoder().decode(
            HLSLiveDVRCheckpoint.self,
            from: Data(contentsOf: checkpointURL)
        )
        let gap = try #require(
            checkpoint.primary.segments.first(where: { $0.isGap == true })
        )
        #expect(gap.playlistPath == "resources/gap-00001.ts")
        #expect(gap.file == nil)

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                gap-recovery-10.ts
                #EXTINF:4,
                gap-recovery-11.ts
                #EXT-X-ENDLIST
                """
            ),
            for: mismatchedURL
        )
        await #expect(throws: HLSLiveDVRError.recoveryMismatch) {
            try await recorder.resume(
                from: mismatchedURL,
                to: fixture.destinationURL
            )
        }

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXTINF:4,
                gap-recovery-10.ts
                #EXT-X-GAP
                #EXTINF:4,
                gap-recovery-11.ts
                #EXTINF:4,
                gap-recovery-12.ts
                #EXT-X-ENDLIST
                """
            ),
            for: resumedURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("third".utf8)),
            for: thirdSegmentURL
        )

        let receipt = try await recorder.resume(
            from: resumedURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 3)
        #expect(receipt.gapCount == 1)
        #expect(receipt.mediaByteCount == 10)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstSegmentURL } == 1)
        #expect(!requests.contains(gapSegmentURL))
        #expect(requests.count { $0 == thirdSegmentURL } == 1)
    }

    @Test("recovery rejects source mismatch and tampered media")
    func rejectsMismatchedOrTamperedRecovery() async throws {
        let sourceURL = try url(
            "https://media.example/integrity.m3u8?token=one"
        )
        let mismatchedURL = try url(
            "https://media.example/other.m3u8?token=two"
        )
        let segmentURL = try url(
            "https://media.example/integrity-10.ts"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        let recorder = try await interruptedRecoveryRecorder(
            sourceURL: sourceURL,
            segmentURL: segmentURL,
            fixture: fixture
        )
        let store = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        )

        await #expect(throws: HLSLiveDVRError.recoveryMismatch) {
            try await recorder.resume(
                from: mismatchedURL,
                to: fixture.destinationURL
            )
        }

        try Data("tampered".utf8).write(
            to: store.workspace.directoryURL.appendingPathComponent(
                "resources/00000.ts"
            )
        )
        await #expect(throws: HLSLiveDVRError.recoveryCorrupted) {
            try await recorder.resume(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, segmentURL]
        )

        try await recorder.discardRecovery(for: fixture.destinationURL)
        try await recorder.discardRecovery(for: fixture.destinationURL)
        #expect(
            !FileManager.default.fileExists(atPath: store.rootURL.path)
        )
    }

    @Test("recovery rejects a symlinked media directory")
    func rejectsSymlinkedRecoveryPath() async throws {
        let sourceURL = try url(
            "https://media.example/symlink-recovery.m3u8"
        )
        let segmentURL = try url(
            "https://media.example/symlink-recovery-10.ts"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        let recorder = try await interruptedRecoveryRecorder(
            sourceURL: sourceURL,
            segmentURL: segmentURL,
            fixture: fixture
        )
        let store = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        )
        let resourcesURL = store.workspace.directoryURL
            .appendingPathComponent("resources", isDirectory: true)
        let externalURL = fixture.rootURL.appendingPathComponent(
            "external-resources",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: resourcesURL,
            to: externalURL
        )
        try FileManager.default.createSymbolicLink(
            at: resourcesURL,
            withDestinationURL: externalURL
        )

        await #expect(throws: HLSLiveDVRError.recoveryCorrupted) {
            try await recorder.resume(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL, segmentURL]
        )
    }

    @Test("discard refuses a recovery directory copied from another destination")
    func discardRequiresDestinationBoundOwnership() async throws {
        let sourceURL = try url(
            "https://media.example/owned-recovery.m3u8"
        )
        let segmentURL = try url(
            "https://media.example/owned-recovery-10.ts"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        let recorder = try await interruptedRecoveryRecorder(
            sourceURL: sourceURL,
            segmentURL: segmentURL,
            fixture: fixture
        )
        let sourceStore = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        )
        let otherDestination = fixture.rootURL.appendingPathComponent(
            "other-recording",
            isDirectory: true
        )
        let otherStore = HLSLiveDVRCheckpointStore(
            destinationURL: otherDestination
        )
        try FileManager.default.copyItem(
            at: sourceStore.rootURL,
            to: otherStore.rootURL
        )

        await #expect(throws: HLSLiveDVRError.recoveryCorrupted) {
            try await recorder.discardRecovery(for: otherDestination)
        }
        #expect(
            FileManager.default.fileExists(atPath: otherStore.rootURL.path)
        )
    }

    @Test("recovery reports when the live window moved past its checkpoint")
    func resumedLiveWindowAdvanceIsTyped() async throws {
        let sourceURL = try url(
            "https://media.example/window-recovery.m3u8?token=one"
        )
        let resumedSourceURL = try url(
            "https://media.example/window-recovery.m3u8?token=two"
        )
        let segmentURL = try url(
            "https://media.example/window-recovery-10.ts"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        let recorder = try await interruptedRecoveryRecorder(
            sourceURL: sourceURL,
            segmentURL: segmentURL,
            fixture: fixture
        )
        let recoveryRoot = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        ).rootURL
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:12
                #EXTINF:4,
                window-recovery-12.ts
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )

        await #expect(throws: HLSLiveDVRError.liveWindowAdvanced) {
            try await recorder.resume(
                from: resumedSourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(FileManager.default.fileExists(atPath: recoveryRoot.path))
    }

    @Test("explicit cancellation removes a durable recovery checkpoint")
    func explicitCancellationDiscardsRecovery() async throws {
        let sourceURL = try url(
            "https://media.example/cancel-recovery.m3u8"
        )
        let segmentURL = try url(
            "https://media.example/cancel-recovery-10.ts"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                uninterruptedRecoveryPlaylist(
                    segmentName: "cancel-recovery-10.ts"
                )
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: segmentURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress(let progress) = try await events.next() else {
            Issue.record("Expected checkpointed progress")
            return
        }
        #expect(progress.segmentCount == 1)

        await recording.cancelAndDiscard()

        let recoveryRoot = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        ).rootURL
        #expect(
            !FileManager.default.fileExists(atPath: recoveryRoot.path)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("rendition checkpoint paths remain package-relative and distinct")
    func renditionCheckpointStoragePathIsDistinct() throws {
        let stored = HLSLiveDVRStoredSegment(
            sequenceNumber: 10,
            duration: 4,
            beginsDiscontinuity: false,
            programDateTime: nil,
            fileName: "resources/00000.aac",
            byteCount: 5,
            contentSHA256: String(repeating: "a", count: 64)
        )

        let checkpoint = HLSLiveDVRCheckpoint.Segment(
            stored,
            storagePrefix: "audio/00"
        )

        #expect(
            try #require(checkpoint.file).relativePath
                == "audio/00/resources/00000.aac"
        )
        #expect(
            try checkpoint.storedSegment().fileName
                == "resources/00000.aac"
        )
    }

    @Test("checkpoint segments reject conflicting gap resources")
    func checkpointGapResourceInvariantIsTyped() throws {
        let invalidGap = try JSONDecoder().decode(
            HLSLiveDVRCheckpoint.Segment.self,
            from: Data(
                """
                {
                  "sequenceNumber": 10,
                  "duration": 4,
                  "beginsDiscontinuity": false,
                  "isGap": true,
                  "playlistPath": "resources/gap-00000.ts",
                  "file": {
                    "relativePath": "resources/gap-00000.ts",
                    "byteCount": 1,
                    "contentSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                  }
                }
                """.utf8
            )
        )
        let invalidMedia = try JSONDecoder().decode(
            HLSLiveDVRCheckpoint.Segment.self,
            from: Data(
                """
                {
                  "sequenceNumber": 10,
                  "duration": 4,
                  "beginsDiscontinuity": false,
                  "isGap": false,
                  "playlistPath": "resources/00000.ts"
                }
                """.utf8
            )
        )
        let legacyMedia = try JSONDecoder().decode(
            HLSLiveDVRCheckpoint.Segment.self,
            from: Data(
                """
                {
                  "sequenceNumber": 10,
                  "duration": 4,
                  "beginsDiscontinuity": false,
                  "playlistPath": "resources/00000.ts",
                  "file": {
                    "relativePath": "resources/00000.ts",
                    "byteCount": 1,
                    "contentSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                  }
                }
                """.utf8
            )
        )

        #expect(throws: HLSLiveDVRError.recoveryCorrupted) {
            try invalidGap.storedSegment()
        }
        #expect(throws: HLSLiveDVRError.recoveryCorrupted) {
            try invalidMedia.storedSegment()
        }
        #expect(try !legacyMedia.storedSegment().isGap)
    }

    @Test("variant recovery identity covers local master attributes")
    func variantRecoveryIdentityCoversMasterAttributes() throws {
        let mediaURL = try url("https://media.example/video.m3u8")
        let baseline = HLSVariant(
            url: mediaURL,
            bandwidth: 1_000,
            closedCaptions: .group("captions"),
            frameRate: 30,
            stableID: "video-main"
        )
        let changedFrameRate = HLSVariant(
            url: mediaURL,
            bandwidth: 1_000,
            closedCaptions: .group("captions"),
            frameRate: 60,
            stableID: "video-main"
        )
        let changedCaptions = HLSVariant(
            url: mediaURL,
            bandwidth: 1_000,
            closedCaptions: .explicitlyNone,
            frameRate: 30,
            stableID: "video-main"
        )

        #expect(
            baseline.liveDVRCheckpointIdentity
                != changedFrameRate.liveDVRCheckpointIdentity
        )
        #expect(
            baseline.liveDVRCheckpointIdentity
                != changedCaptions.liveDVRCheckpointIdentity
        )

        let firstUnsignedIdentity = HLSVariant(
            url: try url(
                "https://media.example/unsigned.m3u8?token=one"
            ),
            bandwidth: 1_000
        ).liveDVRCheckpointIdentity
        let rotatedUnsignedIdentity = HLSVariant(
            url: try url(
                "https://media.example/unsigned.m3u8?token=two"
            ),
            bandwidth: 1_000
        ).liveDVRCheckpointIdentity
        let otherUnsignedIdentity = HLSVariant(
            url: try url(
                "https://media.example/other.m3u8?token=two"
            ),
            bandwidth: 1_000
        ).liveDVRCheckpointIdentity

        #expect(firstUnsignedIdentity == rotatedUnsignedIdentity)
        #expect(firstUnsignedIdentity != otherUnsignedIdentity)
    }

    @Test("rendition recovery identity uses URL when stable ID is absent")
    func renditionRecoveryIdentityUsesURLFallback() throws {
        let rendition: (String) throws -> HLSRendition = { value in
            HLSRendition(
                kind: .audio,
                groupID: "audio",
                name: "Stereo",
                url: try url(value)
            )
        }
        let first = try rendition(
            "https://media.example/audio.m3u8?token=one"
        )
        let rotated = try rendition(
            "https://media.example/audio.m3u8?token=two"
        )
        let other = try rendition(
            "https://media.example/other-audio.m3u8?token=two"
        )

        #expect(
            first.liveDVRCheckpointIdentity
                == rotated.liveDVRCheckpointIdentity
        )
        #expect(
            first.liveDVRCheckpointIdentity
                != other.liveDVRCheckpointIdentity
        )
    }

    @Test("resuming preserves external fMP4 map rotation without collisions")
    func resumesExternalAudioRendition() async throws {
        let masterURL = try url(
            "https://media.example/rendition-recovery.m3u8?token=old"
        )
        let resumedMasterURL = try url(
            "https://media.example/rendition-recovery.m3u8?token=new"
        )
        let oldVideoPlaylistURL = try url(
            "https://media.example/video-recovery.m3u8?token=old"
        )
        let newVideoPlaylistURL = try url(
            "https://media.example/video-recovery.m3u8?token=new"
        )
        let oldAudioPlaylistURL = try url(
            "https://media.example/audio-recovery.m3u8?token=old"
        )
        let newAudioPlaylistURL = try url(
            "https://media.example/audio-recovery.m3u8?token=new"
        )
        let oldVideoURL = try url(
            "https://media.example/video-10.ts?token=old"
        )
        let oldAudioURL = try url(
            "https://media.example/audio-10.m4s?token=old"
        )
        let newVideoURL = try url(
            "https://media.example/video-11.ts?token=new"
        )
        let newAudioURL = try url(
            "https://media.example/audio-11.m4s?token=new"
        )
        let oldAudioMapURL = try url(
            "https://media.example/audio-init-a.mp4?token=old"
        )
        let resumedAudioMapURL = try url(
            "https://media.example/audio-init-a.mp4?token=new"
        )
        let rotatedAudioMapURL = try url(
            "https://media.example/audio-init-b.mp4?token=new"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        let master: (String) -> String = { token in
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",STABLE-RENDITION-ID="audio-main",DEFAULT=YES,URI="audio-recovery.m3u8?token=\(token)"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,STABLE-VARIANT-ID="video-main",AUDIO="audio"
            video-recovery.m3u8?token=\(token)
            """
        }
        let firstPlaylist: (String) -> String = { resource in
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:60
            #EXT-X-MEDIA-SEQUENCE:10
            #EXTINF:4,
            \(resource)
            """
        }
        let resumedPlaylist: (String, String) -> String = { first, second in
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:10
            #EXTINF:4,
            \(first)
            #EXTINF:4,
            \(second)
            #EXT-X-ENDLIST
            """
        }
        let firstAudioPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:60
            #EXT-X-MEDIA-SEQUENCE:10
            #EXT-X-MAP:URI="audio-init-a.mp4?token=old"
            #EXTINF:4,
            audio-10.m4s?token=old
            """
        let resumedAudioPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:10
            #EXT-X-MAP:URI="audio-init-a.mp4?token=new"
            #EXTINF:4,
            audio-10.m4s?token=new
            #EXT-X-DISCONTINUITY
            #EXT-X-MAP:URI="audio-init-b.mp4?token=new"
            #EXTINF:4,
            audio-11.m4s?token=new
            #EXT-X-ENDLIST
            """
        HLSLiveURLProtocol.register(
            playlistResponse(master("old")),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(firstPlaylist("video-10.ts?token=old")),
            for: oldVideoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(firstAudioPlaylist),
            for: oldAudioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("old audio map".utf8)),
            for: oldAudioMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("old video".utf8)),
            for: oldVideoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("old audio".utf8)),
            for: oldAudioURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: masterURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress = try await events.next() else {
            Issue.record("Expected checkpointed rendition media")
            return
        }
        await recording.interrupt()

        HLSLiveURLProtocol.register(
            playlistResponse(master("new")),
            for: resumedMasterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                resumedPlaylist(
                    "video-10.ts?token=new",
                    "video-11.ts?token=new"
                )
            ),
            for: newVideoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(resumedAudioPlaylist),
            for: newAudioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("rotated audio map".utf8)),
            for: rotatedAudioMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("new video".utf8)),
            for: newVideoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("new audio".utf8)),
            for: newAudioURL
        )

        let receipt = try await recorder.resume(
            from: resumedMasterURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 2)
        #expect(receipt.tracks.map(\.kind) == [.primary, .audio])
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == oldVideoURL } == 1)
        #expect(requests.count { $0 == oldAudioURL } == 1)
        #expect(requests.count { $0 == newVideoURL } == 1)
        #expect(requests.count { $0 == newAudioURL } == 1)
        #expect(requests.count { $0 == oldAudioMapURL } == 1)
        #expect(requests.count { $0 == resumedAudioMapURL } == 0)
        #expect(requests.count { $0 == rotatedAudioMapURL } == 1)
        let audioTrack = try #require(
            receipt.tracks.first { $0.kind == .audio }
        )
        let audioPlaylist = try String(
            contentsOf: receipt.directoryURL.appendingPathComponent(
                audioTrack.relativePlaylistPath
            ),
            encoding: .utf8
        )
        #expect(
            audioPlaylist.split(separator: "\n").filter {
                $0.hasPrefix("#EXT-X-MAP:")
            } == [
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\"",
                "#EXT-X-MAP:URI=\"resources/initialization-00001.mp4\"",
            ]
        )
    }

    @Test("resuming AES-128 media refetches rather than persists keys")
    func resumedAES128RefetchesKey() async throws {
        let sourceURL = try url(
            "https://media.example/encrypted-recovery.m3u8?token=old"
        )
        let resumedSourceURL = try url(
            "https://media.example/encrypted-recovery.m3u8?token=new"
        )
        let oldKeyURL = try url(
            "https://media.example/recovery.key?token=old"
        )
        let newKeyURL = try url(
            "https://media.example/recovery.key?token=new"
        )
        let firstSegmentURL = try url(
            "https://media.example/encrypted-recovery-10.ts"
        )
        let secondSegmentURL = try url(
            "https://media.example/encrypted-recovery-11.ts"
        )
        let key = Data(repeating: 0x44, count: 16)
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-KEY:METHOD=AES-128,URI="recovery.key?token=old"
                #EXTINF:4,
                encrypted-recovery-10.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: oldKeyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    Data("first secret".utf8),
                    key: key,
                    initializationVector: sequenceIV(10)
                )
            ),
            for: firstSegmentURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress = try await events.next() else {
            Issue.record("Expected checkpointed encrypted media")
            return
        }
        await recording.interrupt()

        let checkpointURL = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        ).rootURL.appendingPathComponent("checkpoint.json")
        let checkpoint = try String(
            contentsOf: checkpointURL,
            encoding: .utf8
        )
        #expect(!checkpoint.contains("recovery.key"))
        #expect(!checkpoint.contains(key.base64EncodedString()))

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-KEY:METHOD=AES-128,URI="recovery.key?token=new"
                #EXTINF:4,
                encrypted-recovery-10.ts
                #EXTINF:4,
                encrypted-recovery-11.ts
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: newKeyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    Data("second secret".utf8),
                    key: key,
                    initializationVector: sequenceIV(11)
                )
            ),
            for: secondSegmentURL
        )

        let receipt = try await recorder.resume(
            from: resumedSourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 2)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == oldKeyURL } == 1)
        #expect(requests.count { $0 == newKeyURL } == 1)
        #expect(requests.count { $0 == firstSegmentURL } == 1)
        #expect(requests.count { $0 == secondSegmentURL } == 1)
    }

    @Test("recovery rejects a changed fragmented MP4 initialization map")
    func rejectsChangedInitializationMapOnResume() async throws {
        let sourceURL = try url(
            "https://media.example/map-recovery.m3u8?token=old"
        )
        let resumedSourceURL = try url(
            "https://media.example/map-recovery.m3u8?token=new"
        )
        let initializationURL = try url(
            "https://media.example/original-init.mp4?token=old"
        )
        let segmentURL = try url(
            "https://media.example/map-recovery-10.m4s"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-MAP:URI="original-init.mp4?token=old"
                #EXTINF:4,
                map-recovery-10.m4s
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("initialization".utf8)),
            for: initializationURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: segmentURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress = try await events.next() else {
            Issue.record("Expected checkpointed fragmented MP4 media")
            return
        }
        await recording.interrupt()

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-MAP:URI="replacement-init.mp4?token=new"
                #EXTINF:4,
                map-recovery-10.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )

        await #expect(throws: HLSLiveDVRError.recoveryMismatch) {
            try await recorder.resume(
                from: resumedSourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                .count == 4
        )
    }

    @Test("record-from-now skips the initial live window")
    func recordsNextCompletedSegment() async throws {
        let sourceURL = try url("https://media.example/next.m3u8")
        let reloadURL = try url(
            "https://media.example/next.m3u8?_HLS_msn=2"
        )
        let firstURL = try url("https://media.example/1.ts")
        let secondURL = try url("https://media.example/2.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                1.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                1.ts
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 1)
        #expect(receipt.firstMediaSequence == 2)
        #expect(receipt.lastMediaSequence == 2)
        let requestedURLs =
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requestedURLs == [sourceURL, reloadURL, secondURL])
        #expect(!requestedURLs.contains(firstURL))
    }

    @Test("fragmented MP4 retains one stable initialization map")
    func recordsFragmentedMP4() async throws {
        let sourceURL = try url("https://media.example/fmp4.m3u8")
        let initializationURL = try url(
            "https://media.example/init.mp4"
        )
        let segmentURL = try url("https://media.example/1.m4s")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:4,
                1.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("init".utf8)),
            for: initializationURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("media".utf8)),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.mediaByteCount == 9)
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(
            playlist.contains(
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\""
            )
        )
        #expect(!playlist.contains(initializationURL.absoluteString))
    }

    @Test("fragmented MP4 preserves initialization map rotation")
    func recordsFragmentedMP4MapRotation() async throws {
        let sourceURL = try url("https://media.example/map-rotation.m3u8")
        let firstMapURL = try url("https://media.example/init-a.mp4")
        let secondMapURL = try url("https://media.example/init-b.mp4")
        let segmentURLs = try [1, 2, 3].map {
            try url("https://media.example/\($0).m4s")
        }
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-MAP:URI="init-a.mp4"
                #EXTINF:4,
                1.m4s
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="init-b.mp4"
                #EXTINF:4,
                2.m4s
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="init-a.mp4"
                #EXTINF:4,
                3.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-a".utf8)),
            for: firstMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-b".utf8)),
            for: secondMapURL
        )
        for (index, segmentURL) in segmentURLs.enumerated() {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("segment-\(index + 1)".utf8)),
                for: segmentURL
            )
        }

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 3)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstMapURL } == 1)
        #expect(requests.count { $0 == secondMapURL } == 1)
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        let mapLines = playlist.split(separator: "\n").filter {
            $0.hasPrefix("#EXT-X-MAP:")
        }
        #expect(
            mapLines == [
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\"",
                "#EXT-X-MAP:URI=\"resources/initialization-00001.mp4\"",
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\"",
            ]
        )
        #expect(!playlist.contains("media.example"))
    }

    @Test("fragmented MP4 gaps retain their initialization-map boundary")
    func recordsFragmentedMP4GapMapBoundary() async throws {
        let sourceURL = try url("https://media.example/fmp4-gap.m3u8")
        let firstMapURL = try url("https://media.example/gap-init-a.mp4")
        let gapMapURL = try url("https://media.example/gap-init-b.mp4")
        let firstSegmentURL = try url(
            "https://media.example/fmp4-gap-1.m4s"
        )
        let gapSegmentURL = try url(
            "https://media.example/fmp4-gap-2.m4s"
        )
        let thirdSegmentURL = try url(
            "https://media.example/fmp4-gap-3.m4s"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-MAP:URI="gap-init-a.mp4"
                #EXTINF:4,
                fmp4-gap-1.m4s
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="gap-init-b.mp4"
                #EXT-X-GAP
                #EXTINF:4,
                fmp4-gap-2.m4s
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="gap-init-a.mp4"
                #EXTINF:4,
                fmp4-gap-3.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-a".utf8)),
            for: firstMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-b".utf8)),
            for: gapMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstSegmentURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("third".utf8)),
            for: thirdSegmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 3)
        #expect(receipt.gapCount == 1)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstMapURL } == 1)
        #expect(requests.count { $0 == gapMapURL } == 1)
        #expect(!requests.contains(gapSegmentURL))
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(
            playlist.split(separator: "\n").filter {
                $0.hasPrefix("#EXT-X-MAP:")
            } == [
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\"",
                "#EXT-X-MAP:URI=\"resources/initialization-00001.mp4\"",
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\"",
            ]
        )
        #expect(
            playlist.contains(
                "#EXT-X-GAP\n#EXTINF:4.0,\nresources/gap-00001.m4s"
            )
        )
    }

    @Test("resumable DVR accepts a new map after checkpointed media")
    func resumesAfterInitializationMapRotation() async throws {
        let sourceURL = try url("https://media.example/map-resume.m3u8")
        let resumedSourceURL = try url(
            "https://media.example/map-resume.m3u8?resume=1"
        )
        let firstMapURL = try url("https://media.example/resume-a.mp4")
        let secondMapURL = try url("https://media.example/resume-b.mp4")
        let firstSegmentURL = try url(
            "https://media.example/map-resume-10.m4s"
        )
        let secondSegmentURL = try url(
            "https://media.example/map-resume-11.m4s"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-MAP:URI="resume-a.mp4"
                #EXTINF:4,
                map-resume-10.m4s
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("resume-a".utf8)),
            for: firstMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstSegmentURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress = try await events.next() else {
            Issue.record("Expected checkpointed fragmented MP4 media")
            return
        }
        await recording.interrupt()

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-MAP:URI="resume-a.mp4"
                #EXTINF:4,
                map-resume-10.m4s
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="resume-b.mp4"
                #EXTINF:4,
                map-resume-11.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("resume-b".utf8)),
            for: secondMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondSegmentURL
        )

        let receipt = try await recorder.resume(
            from: resumedSourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 2)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstMapURL } == 1)
        #expect(requests.count { $0 == secondMapURL } == 1)
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(
            playlist.contains(
                "#EXT-X-MAP:URI=\"resources/initialization-00001.mp4\""
            )
        )
    }

    @Test("an unreferenced rotated map is removed at the byte limit")
    func removesUnreferencedMapAtByteLimit() async throws {
        let sourceURL = try url(
            "https://media.example/map-byte-limit.m3u8"
        )
        let firstMapURL = try url("https://media.example/limit-a.mp4")
        let secondMapURL = try url("https://media.example/limit-b.mp4")
        let firstSegmentURL = try url(
            "https://media.example/map-limit-1.m4s"
        )
        let secondSegmentURL = try url(
            "https://media.example/map-limit-2.m4s"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-MAP:URI="limit-a.mp4"
                #EXTINF:4,
                map-limit-1.m4s
                #EXT-X-MAP:URI="limit-b.mp4"
                #EXTINF:4,
                map-limit-2.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("a".utf8)),
            for: firstMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("b".utf8)),
            for: secondMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("1".utf8)),
            for: firstSegmentURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("segment-two".utf8)),
            for: secondSegmentURL
        )
        let configuration = HLSLiveDVRConfiguration.advanced(
            limits: HLSLiveDVRLimitPack(
                maximumDuration: 60,
                maximumSegmentCount: 20,
                maximumMediaResourceBytes: 1_024,
                maximumTotalMediaBytes: 3
            ),
            startPosition: .currentWindow
        )

        let receipt = try await HLSLiveDVRRecorder(
            client: HLSLivePlaylistClient(session: fixture.session),
            configuration: configuration
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.mediaByteCount == 2)
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL.appendingPathComponent(
                    "resources/initialization-00001.mp4"
                ).path
            )
        )
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(
            playlist.split(separator: "\n").count {
                $0.hasPrefix("#EXT-X-MAP:")
            } == 1
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(secondMapURL))
        #expect(!requests.contains(secondSegmentURL))
    }

    @Test("LL-HLS parts do not promote across a map rotation")
    func rejectsPartPromotionAcrossMapRotation() async throws {
        let sourceURL = try url("https://media.example/part-map.m3u8")
        let reloadURL = try url(
            "https://media.example/part-map.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstMapURL = try url("https://media.example/part-map-a.mp4")
        let secondMapURL = try url("https://media.example/part-map-b.mp4")
        let firstPartURL = try url("https://media.example/11.0.m4s")
        let secondPartURL = try url("https://media.example/11.1.m4s")
        let parentURL = try url("https://media.example/11.m4s")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=4
                #EXT-X-PART-INF:PART-TARGET=2
                #EXT-X-MAP:URI="part-map-a.mp4"
                #EXTINF:4,
                10.m4s
                #EXT-X-PART:DURATION=2,URI="11.0.m4s",INDEPENDENT=YES
                #EXT-X-PART:DURATION=2,URI="11.1.m4s"
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=4
                #EXT-X-PART-INF:PART-TARGET=2
                #EXT-X-MAP:URI="part-map-a.mp4"
                #EXTINF:4,
                10.m4s
                #EXT-X-PART:DURATION=2,URI="11.0.m4s",INDEPENDENT=YES
                #EXT-X-PART:DURATION=2,URI="11.1.m4s"
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="part-map-b.mp4"
                #EXTINF:4,
                11.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-b".utf8)),
            for: secondMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("parent".utf8)),
            for: parentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 0)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(!requests.contains(firstMapURL))
        #expect(requests.contains(secondMapURL))
        #expect(requests.contains(parentURL))
    }

    @Test("legacy single-map checkpoints remain resumable")
    func resumesLegacySingleMapCheckpoint() async throws {
        let sourceURL = try url(
            "https://media.example/legacy-map-checkpoint.m3u8"
        )
        let resumedSourceURL = try url(
            "https://media.example/legacy-map-checkpoint.m3u8?resume=1"
        )
        let mapURL = try url("https://media.example/legacy-map.mp4")
        let firstSegmentURL = try url(
            "https://media.example/legacy-map-10.m4s"
        )
        let secondSegmentURL = try url(
            "https://media.example/legacy-map-11.m4s"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-MAP:URI="legacy-map.mp4"
                #EXTINF:4,
                legacy-map-10.m4s
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("legacy-map".utf8)),
            for: mapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstSegmentURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress = try await events.next() else {
            Issue.record("Expected checkpointed fragmented MP4 media")
            return
        }
        await recording.interrupt()

        let checkpointURL = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        ).rootURL.appendingPathComponent("checkpoint.json")
        let checkpointData = try Data(contentsOf: checkpointURL)
        var checkpoint = try #require(
            JSONSerialization.jsonObject(with: checkpointData)
                as? [String: Any]
        )
        checkpoint.removeValue(forKey: "retentionPolicy")
        checkpoint.removeValue(forKey: "retentionStatistics")
        var primary = try #require(
            checkpoint["primary"] as? [String: Any]
        )
        primary.removeValue(forKey: "initializations")
        var segments = try #require(
            primary["segments"] as? [[String: Any]]
        )
        for index in segments.indices {
            segments[index].removeValue(
                forKey: "initializationSourceIdentity"
            )
            segments[index].removeValue(
                forKey: "initializationPlaylistPath"
            )
        }
        primary["segments"] = segments
        checkpoint["primary"] = primary
        try JSONSerialization.data(
            withJSONObject: checkpoint,
            options: [.sortedKeys]
        ).write(to: checkpointURL, options: .atomic)

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-MAP:URI="legacy-map.mp4"
                #EXTINF:4,
                legacy-map-10.m4s
                #EXTINF:4,
                legacy-map-11.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondSegmentURL
        )

        let receipt = try await recorder.resume(
            from: resumedSourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 2)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == mapURL } == 1)
        #expect(requests.count { $0 == firstSegmentURL } == 1)
        #expect(requests.count { $0 == secondSegmentURL } == 1)
    }

    @Test("segment count stops recording before another media request")
    func segmentCountStopsRecording() async throws {
        let sourceURL = try url("https://media.example/bounded.m3u8")
        let firstURL = try url("https://media.example/1.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                1.ts
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )

        let client = HLSLivePlaylistClient(
            session: fixture.session
        )
        let configuration = HLSLiveDVRConfiguration.advanced(
            limits: HLSLiveDVRLimitPack(
                maximumDuration: 60,
                maximumSegmentCount: 1,
                maximumMediaResourceBytes: 1_024,
                maximumTotalMediaBytes: 1_024
            ),
            startPosition: .currentWindow
        )
        let receipt = try await HLSLiveDVRRecorder(
            client: client,
            configuration: configuration
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 1)
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, firstURL]
        )
    }

    @Test("rolling retention keeps the newest complete segments")
    func rollingRetentionKeepsNewestSegments() async throws {
        let sourceURL = try url("https://media.example/rolling.m3u8")
        let segmentURLs = try (1...4).map {
            try url("https://media.example/rolling-\($0).ts")
        }
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                rolling-1.ts
                #EXTINF:4,
                rolling-2.ts
                #EXTINF:4,
                rolling-3.ts
                #EXTINF:4,
                rolling-4.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        for (index, segmentURL) in segmentURLs.enumerated() {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("media-\(index + 1)".utf8)),
                for: segmentURL
            )
        }

        var progress: HLSLiveDVRProgress?
        var completedReceipt: HLSLiveDVRReceipt?
        for try await event in rollingRecorder(
            session: fixture.session,
            maximumSegmentCount: 2
        ).events(from: sourceURL, to: fixture.destinationURL) {
            switch event {
            case .progress(let snapshot):
                progress = snapshot
            case .completed(let receipt):
                completedReceipt = receipt
            }
        }
        let receipt = try #require(completedReceipt)

        #expect(receipt.segmentCount == 2)
        #expect(receipt.recordedDuration == 8)
        #expect(receipt.firstMediaSequence == 3)
        #expect(receipt.lastMediaSequence == 4)
        #expect(
            receipt.retentionStatistics
                == HLSLiveDVRRetentionStatistics(
                    evictedPrimarySegmentCount: 2,
                    evictedPrimaryDuration: 8,
                    evictedMediaByteCount: 14
                )
        )
        #expect(progress?.retentionStatistics == receipt.retentionStatistics)
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:3"))
        #expect(playlist.contains("resources/sequence-3.ts"))
        #expect(playlist.contains("resources/sequence-4.ts"))
        #expect(!playlist.contains("sequence-1.ts"))
        #expect(!playlist.contains("sequence-2.ts"))
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL.appendingPathComponent(
                    "resources/sequence-1.ts"
                ).path
            )
        )
    }

    @Test("rolling duration retention evicts a complete prefix")
    func rollingDurationRetentionKeepsCompleteSuffix() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-duration.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:20
                #EXTINF:2,
                duration-20.ts
                #EXTINF:3,
                duration-21.ts
                #EXTINF:4,
                duration-22.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        for sequence in 20...22 {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("\(sequence)".utf8)),
                for: try url(
                    "https://media.example/duration-\(sequence).ts"
                )
            )
        }

        let receipt = try await rollingRecorder(
            session: fixture.session,
            maximumDuration: 5,
            maximumSegmentCount: 20
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.recordedDuration == 4)
        #expect(receipt.firstMediaSequence == 22)
        #expect(
            receipt.retentionStatistics.evictedPrimarySegmentCount == 2
        )
        #expect(receipt.retentionStatistics.evictedPrimaryDuration == 5)
    }

    @Test("rolling byte retention reclaims old media")
    func rollingByteRetentionReclaimsOldMedia() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-bytes.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:30
                #EXTINF:4,
                bytes-30.ts
                #EXTINF:4,
                bytes-31.ts
                #EXTINF:4,
                bytes-32.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        for sequence in 30...32 {
            HLSLiveURLProtocol.register(
                mediaResponse(Data(repeating: UInt8(sequence), count: 4)),
                for: try url(
                    "https://media.example/bytes-\(sequence).ts"
                )
            )
        }

        let receipt = try await rollingRecorder(
            session: fixture.session,
            maximumSegmentCount: 20,
            maximumTotalMediaBytes: 8
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 2)
        #expect(receipt.mediaByteCount == 8)
        #expect(receipt.firstMediaSequence == 31)
        #expect(receipt.retentionStatistics.evictedMediaByteCount == 4)
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL.appendingPathComponent(
                    "resources/sequence-30.ts"
                ).path
            )
        )
    }

    @Test("rolling retention removes an expired declared gap")
    func rollingRetentionEvictsDeclaredGap() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-gap.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:40
                #EXT-X-GAP
                #EXTINF:4,
                gap-40.ts
                #EXTINF:4,
                gap-41.ts
                #EXTINF:4,
                gap-42.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        for sequence in 41...42 {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("\(sequence)".utf8)),
                for: try url("https://media.example/gap-\(sequence).ts")
            )
        }

        let receipt = try await rollingRecorder(
            session: fixture.session,
            maximumSegmentCount: 2
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 2)
        #expect(receipt.gapCount == 0)
        #expect(receipt.firstMediaSequence == 41)
        #expect(
            receipt.retentionStatistics
                == HLSLiveDVRRetentionStatistics(
                    evictedPrimarySegmentCount: 1,
                    evictedPrimaryDuration: 4,
                    evictedMediaByteCount: 0
                )
        )
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(!playlist.contains("#EXT-X-GAP"))
    }

    @Test("rolling fMP4 retention prunes and safely reloads maps")
    func rollingRetentionReintroducesInitializationMap() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-map.m3u8"
        )
        let firstMapURL = try url("https://media.example/map-a.mp4")
        let secondMapURL = try url("https://media.example/map-b.mp4")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:50
                #EXT-X-MAP:URI="map-a.mp4"
                #EXTINF:4,
                map-50.m4s
                #EXT-X-MAP:URI="map-b.mp4"
                #EXTINF:4,
                map-51.m4s
                #EXT-X-MAP:URI="map-a.mp4"
                #EXTINF:4,
                map-52.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-a".utf8)),
            for: firstMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-a".utf8)),
            for: firstMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-b".utf8)),
            for: secondMapURL
        )
        for sequence in 50...52 {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("segment-\(sequence)".utf8)),
                for: try url(
                    "https://media.example/map-\(sequence).m4s"
                )
            )
        }

        let receipt = try await rollingRecorder(
            session: fixture.session,
            maximumSegmentCount: 1
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.firstMediaSequence == 52)
        #expect(
            receipt.retentionStatistics.evictedPrimarySegmentCount == 2
        )
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(playlist.contains("#EXT-X-MAP:"))
        #expect(playlist.contains("-52.mp4"))
        #expect(playlist.contains("resources/sequence-52.m4s"))
        let resourceNames = try packageFileURLs(
            receipt.directoryURL.appendingPathComponent("resources")
        ).map(\.lastPathComponent)
        #expect(resourceNames.count == 2)
        #expect(resourceNames.contains("sequence-52.m4s"))
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstMapURL } == 2)
        #expect(requests.count { $0 == secondMapURL } == 1)
    }

    @Test("rolling retention keeps external audio aligned")
    func rollingRetentionKeepsExternalAudioAligned() async throws {
        let masterURL = try url(
            "https://media.example/rolling-master.m3u8"
        )
        let videoPlaylistURL = try url(
            "https://media.example/rolling-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/rolling-audio.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="rolling-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                rolling-video.m3u8
                """
            ),
            for: masterURL
        )
        let mediaPlaylist: (String, String) -> String = { prefix, suffix in
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:60
            #EXTINF:4,
            \(prefix)-60.\(suffix)
            #EXTINF:4,
            \(prefix)-61.\(suffix)
            #EXTINF:4,
            \(prefix)-62.\(suffix)
            #EXT-X-ENDLIST
            """
        }
        HLSLiveURLProtocol.register(
            playlistResponse(mediaPlaylist("video", "ts")),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(mediaPlaylist("audio", "aac")),
            for: audioPlaylistURL
        )
        for sequence in 60...62 {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("video-\(sequence)".utf8)),
                for: try url(
                    "https://media.example/video-\(sequence).ts"
                )
            )
            HLSLiveURLProtocol.register(
                mediaResponse(Data("audio-\(sequence)".utf8)),
                for: try url(
                    "https://media.example/audio-\(sequence).aac"
                )
            )
        }

        let receipt = try await rollingRecorder(
            session: fixture.session,
            maximumDuration: 5,
            maximumSegmentCount: 20
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(receipt.firstMediaSequence == 62)
        let audioTrack = try #require(
            receipt.tracks.first { $0.kind == .audio }
        )
        let audioDirectory = receipt.directoryURL.appendingPathComponent(
            audioTrack.relativePlaylistPath
        ).deletingLastPathComponent()
        let audioPlaylist = try String(
            contentsOf: audioDirectory.appendingPathComponent("index.m3u8"),
            encoding: .utf8
        )
        #expect(audioPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:62"))
        #expect(audioPlaylist.contains("resources/sequence-62.aac"))
        #expect(
            !FileManager.default.fileExists(
                atPath: audioDirectory.appendingPathComponent(
                    "resources/sequence-60.aac"
                ).path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: audioDirectory.appendingPathComponent(
                    "resources/sequence-61.aac"
                ).path
            )
        )
    }

    @Test("rolling retention does not prefetch future external media")
    func rollingRetentionDoesNotPrefetchFutureExternalMedia() async throws {
        let masterURL = try url(
            "https://media.example/rolling-future-master.m3u8"
        )
        let videoPlaylistURL = try url(
            "https://media.example/rolling-future-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/rolling-future-audio.m3u8"
        )
        let videoURL = try url(
            "https://media.example/rolling-future-video.ts"
        )
        let audioURL = try url(
            "https://media.example/rolling-future-audio.aac"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="rolling-future-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                rolling-future-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:100
                #EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:00Z
                #EXTINF:4,
                rolling-future-video.ts
                #EXT-X-ENDLIST
                """
            ),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:200
                #EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:01:00Z
                #EXTINF:4,
                rolling-future-audio.aac
                #EXT-X-ENDLIST
                """
            ),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("video".utf8)),
            for: videoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("audio".utf8)),
            for: audioURL
        )

        await #expect(
            throws: HLSLiveDVRError.unsupportedFeature(
                .incompleteExternalRendition
            )
        ) {
            try await rollingRecorder(
                session: fixture.session,
                maximumSegmentCount: 2
            ).record(from: masterURL, to: fixture.destinationURL)
        }
        #expect(
            !HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                .contains(audioURL)
        )
    }

    @Test("rolling recovery checkpoints only the retained suffix")
    func rollingRecoveryResumesRetainedSuffix() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-recovery.m3u8?token=old"
        )
        let resumedSourceURL = try url(
            "https://media.example/rolling-recovery.m3u8?token=new"
        )
        let segmentURLs = try (70...73).map {
            try url("https://media.example/recovery-\($0).ts")
        }
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:60
                #EXT-X-MEDIA-SEQUENCE:70
                #EXTINF:4,
                recovery-70.ts
                #EXTINF:4,
                recovery-71.ts
                #EXTINF:4,
                recovery-72.ts
                """
            ),
            for: sourceURL
        )
        for (index, segmentURL) in segmentURLs.dropLast().enumerated() {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("media-\(index)".utf8)),
                for: segmentURL
            )
        }
        let recorder = rollingRecorder(
            session: fixture.session,
            maximumSegmentCount: 2,
            recovery: HLSLiveDVRRecoveryPack(policy: .resumable)
        )
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        var observedEviction = false
        while case .progress(let progress) = try await events.next() {
            if progress.retentionStatistics.evictedPrimarySegmentCount == 1 {
                observedEviction = true
                break
            }
        }
        #expect(observedEviction)
        await recording.interrupt()

        let recoveryRoot = HLSLiveDVRCheckpointStore(
            destinationURL: fixture.destinationURL
        ).rootURL
        let recoveryPackage = recoveryRoot.appendingPathComponent(
            "package",
            isDirectory: true
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: recoveryPackage.appendingPathComponent(
                    "resources/sequence-70.ts"
                ).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: recoveryPackage.appendingPathComponent(
                    "resources/sequence-71.ts"
                ).path
            )
        )
        let checkpoint = try JSONDecoder().decode(
            HLSLiveDVRCheckpoint.self,
            from: Data(
                contentsOf: recoveryRoot.appendingPathComponent(
                    "checkpoint.json"
                )
            )
        )
        #expect(checkpoint.retentionPolicy == "rollingWindow")
        #expect(
            checkpoint.retentionStatistics?
                .evictedPrimarySegmentCount == 1
        )
        #expect(
            checkpoint.primary.segments.map(\.sequenceNumber) == [71, 72]
        )

        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:71
                #EXTINF:4,
                recovery-71.ts
                #EXTINF:4,
                recovery-72.ts
                #EXTINF:4,
                recovery-73.ts
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:71
                #EXTINF:4,
                recovery-71.ts
                #EXTINF:4,
                recovery-72.ts
                #EXTINF:4,
                recovery-73.ts
                #EXT-X-ENDLIST
                """
            ),
            for: resumedSourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("media-3".utf8)),
            for: segmentURLs[3]
        )

        let stopAtLimitRecorder = self.recorder(
            session: fixture.session,
            startPosition: .currentWindow,
            recovery: HLSLiveDVRRecoveryPack(policy: .resumable)
        )
        await #expect(throws: HLSLiveDVRError.recoveryMismatch) {
            try await stopAtLimitRecorder.resume(
                from: resumedSourceURL,
                to: fixture.destinationURL
            )
        }

        let receipt = try await recorder.resume(
            from: resumedSourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.firstMediaSequence == 72)
        #expect(receipt.lastMediaSequence == 73)
        #expect(
            receipt.retentionStatistics.evictedPrimarySegmentCount == 2
        )
        #expect(receipt.retentionStatistics.evictedPrimaryDuration == 8)
        let mediaRequests = HLSLiveURLProtocol.capturedRequests()
            .compactMap(\.url)
            .filter { $0.pathExtension == "ts" }
        #expect(mediaRequests == segmentURLs)
    }

    @Test("rolling retention reclaims a segment replaced by LL-HLS parts")
    func rollingRetentionEvictsBeforePartPromotion() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-parts.m3u8"
        )
        let reloadURL = try url(
            "https://media.example/rolling-parts.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstSegmentURL = try url("https://media.example/10.ts")
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(partialPlaylist()),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(completedPartialPlaylist()),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("ten".utf8)),
            for: firstSegmentURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )

        let receipt = try await rollingRecorder(
            session: fixture.session,
            maximumSegmentCount: 1,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.firstMediaSequence == 11)
        #expect(receipt.promotedPartCount == 2)
        #expect(receipt.mediaByteCount == 6)
        #expect(
            receipt.retentionStatistics.evictedPrimarySegmentCount == 1
        )
        #expect(receipt.retentionStatistics.evictedMediaByteCount == 3)
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/sequence-11.ts"
                )
            ) == Data("onetwo".utf8)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL.appendingPathComponent(
                    "resources/sequence-10.ts"
                ).path
            )
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(firstSegmentURL))
        #expect(!requests.contains(parentURL))
    }

    @Test("event streams emit bounded progress and a terminal receipt")
    func eventStreamEmitsProgressAndReceipt() async throws {
        let sourceURL = try url("https://media.example/events.m3u8")
        let segmentURL = try url("https://media.example/event.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:7
                #EXTINF:4,
                event.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("event".utf8)),
            for: segmentURL
        )

        var events: [HLSLiveDVREvent] = []
        for try await event in recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).events(
            from: sourceURL,
            to: fixture.destinationURL
        ) {
            events.append(event)
        }

        #expect(events.count == 2)
        #expect(
            events.first
                == .progress(
                    HLSLiveDVRProgress(
                        segmentCount: 1,
                        recordedDuration: 4,
                        mediaByteCount: 5
                    )
                )
        )
        guard case .completed(let receipt) = events.last else {
            Issue.record("Expected a terminal live DVR receipt.")
            return
        }
        #expect(receipt.segmentCount == 1)
        #expect(receipt.firstMediaSequence == 7)
    }

    @Test("byte ranges require exact partial responses")
    func recordsExactByteRange() async throws {
        let sourceURL = try url("https://media.example/range.m3u8")
        let segmentURL = try url("https://media.example/range.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                #EXT-X-BYTERANGE:4@2
                range.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 206,
                data: Data("2345".utf8),
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 2-5/8",
                ]
            ),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.mediaByteCount == 4)
        let mediaRequest = try #require(
            HLSLiveURLProtocol.capturedRequests().last
        )
        #expect(
            mediaRequest.value(
                forHTTPHeaderField: "Range"
            ) == "bytes=2-5"
        )
        #expect(
            mediaRequest.value(
                forHTTPHeaderField: "Accept-Encoding"
            ) == "identity"
        )
    }

    @Test("AES-128 byte ranges validate ciphertext and retain plaintext")
    func recordsEncryptedByteRange() async throws {
        let sourceURL = try url("https://media.example/encrypted-range.m3u8")
        let keyURL = try url("https://media.example/range.key")
        let segmentURL = try url("https://media.example/range.bin")
        let key = Data(repeating: 0x51, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([5])
        let plaintext = Data("encrypted ranged media".utf8)
        let ciphertext = try aes128Encrypt(
            plaintext,
            key: key,
            initializationVector: initializationVector
        )
        let lowerBound: Int64 = 10
        let upperBound = lowerBound + Int64(ciphertext.count) - 1
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-KEY:METHOD=AES-128,URI="range.key",IV=0x00000000000000000000000000000005
                #EXTINF:4,
                #EXT-X-BYTERANGE:\(ciphertext.count)@\(lowerBound)
                range.bin
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 206,
                data: ciphertext,
                headers: [
                    "Content-Length": "\(ciphertext.count)",
                    "Content-Range":
                        "bytes \(lowerBound)-\(upperBound)/100",
                ]
            ),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.mediaByteCount == Int64(plaintext.count))
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.bin")
            ) == plaintext
        )
        let mediaRequest = try #require(
            HLSLiveURLProtocol.capturedRequests().last
        )
        #expect(
            mediaRequest.value(forHTTPHeaderField: "Range")
                == "bytes=\(lowerBound)-\(upperBound)"
        )
    }

    @Test("total byte limit commits only complete retained segments")
    func totalByteLimitStopsAtSegmentBoundary() async throws {
        let sourceURL = try url("https://media.example/bytes.m3u8")
        let firstURL = try url("https://media.example/first.ts")
        let secondURL = try url("https://media.example/second.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                first.ts
                #EXTINF:4,
                second.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )
        let recorder = HLSLiveDVRRecorder(
            client: HLSLivePlaylistClient(
                session: fixture.session
            ),
            configuration: .advanced(
                limits: HLSLiveDVRLimitPack(
                    maximumDuration: 60,
                    maximumSegmentCount: 20,
                    maximumMediaResourceBytes: 1_024,
                    maximumTotalMediaBytes: 6
                ),
                startPosition: .currentWindow
            )
        )

        let receipt = try await recorder.record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.segmentCount == 1)
        #expect(receipt.mediaByteCount == 5)
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, firstURL, secondURL]
        )
    }

    @Test("AES-128 media is decrypted into a key-free local package")
    func recordsAES128Media() async throws {
        let sourceURL = try url(
            "https://media.example/encrypted.m3u8"
        )
        let keyURL = try url("https://media.example/key.bin")
        let segmentURL = try url("https://media.example/1.ts")
        let key = Data("0123456789abcdef".utf8)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([1])
        let plaintext = Data("decrypted live media".utf8)
        let ciphertext = try aes128Encrypt(
            plaintext,
            key: key,
            initializationVector: initializationVector
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
                #EXTINF:4,
                1.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(key),
            for: keyURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(ciphertext),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: sourceURL,
            to: fixture.destinationURL
        )

        #expect(receipt.mediaByteCount == Int64(plaintext.count))
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.ts")
            ) == plaintext
        )
        let playlist = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        #expect(!playlist.contains("#EXT-X-KEY"))
        #expect(!playlist.contains(keyURL.absoluteString))
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [sourceURL, keyURL, segmentURL]
        )
        #expect(
            try packageFileNames(receipt.directoryURL)
                .allSatisfy { !$0.contains("ciphertext") }
        )
        #expect(
            try packageFileData(receipt.directoryURL)
                .allSatisfy { $0.range(of: key) == nil }
        )
    }

    @Test("implicit media-sequence IVs reuse one in-memory key")
    func recordsImplicitIVAndReusesKey() async throws {
        let sourceURL = try url("https://media.example/implicit.m3u8")
        let keyURL = try url("https://media.example/implicit-key.bin")
        let firstURL = try url("https://media.example/257.ts")
        let secondURL = try url("https://media.example/258.ts")
        let key = Data(repeating: 0x11, count: 16)
        let firstPlaintext = Data("first implicit segment".utf8)
        let secondPlaintext = Data("second implicit segment".utf8)
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:257
                #EXT-X-KEY:METHOD=AES-128,URI="implicit-key.bin"
                #EXTINF:4,
                257.ts
                #EXTINF:4,
                258.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    firstPlaintext,
                    key: key,
                    initializationVector: sequenceIV(257)
                )
            ),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    secondPlaintext,
                    key: key,
                    initializationVector: sequenceIV(258)
                )
            ),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.ts")
            ) == firstPlaintext
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00001.ts")
            ) == secondPlaintext
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                .count { $0 == keyURL } == 1
        )
    }

    @Test("AES-128 key rotation fetches each key once")
    func recordsRotatedAES128Keys() async throws {
        let sourceURL = try url("https://media.example/rotation.m3u8")
        let firstKeyURL = try url("https://media.example/first.key")
        let secondKeyURL = try url("https://media.example/second.key")
        let firstURL = try url("https://media.example/1.ts")
        let secondURL = try url("https://media.example/2.ts")
        let firstKey = Data(repeating: 0x21, count: 16)
        let secondKey = Data(repeating: 0x22, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([9])
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-KEY:METHOD=AES-128,URI="first.key",IV=0x00000000000000000000000000000009
                #EXTINF:4,
                1.ts
                #EXT-X-KEY:METHOD=AES-128,URI="second.key",IV=0x00000000000000000000000000000009
                #EXTINF:4,
                2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(firstKey), for: firstKeyURL)
        HLSLiveURLProtocol.register(mediaResponse(secondKey), for: secondKeyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    Data("first rotated".utf8),
                    key: firstKey,
                    initializationVector: initializationVector
                )
            ),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    Data("second rotated".utf8),
                    key: secondKey,
                    initializationVector: initializationVector
                )
            ),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 2)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstKeyURL } == 1)
        #expect(requests.count { $0 == secondKeyURL } == 1)
    }

    @Test("encrypted fragmented MP4 decrypts rotated maps and media")
    func recordsEncryptedFragmentedMP4() async throws {
        let sourceURL = try url("https://media.example/encrypted-fmp4.m3u8")
        let keyURL = try url("https://media.example/fmp4.key")
        let initializationURLs = try [1, 2].map {
            try url("https://media.example/init-\($0).mp4")
        }
        let segmentURLs = try [1, 2].map {
            try url("https://media.example/encrypted-\($0).m4s")
        }
        let key = Data(repeating: 0x31, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([3])
        let initializationPlaintexts = [
            Data("encrypted init one".utf8),
            Data("encrypted init two".utf8),
        ]
        let mediaPlaintexts = [
            Data("encrypted fragment one".utf8),
            Data("encrypted fragment two".utf8),
        ]
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-KEY:METHOD=AES-128,URI="fmp4.key",IV=0x00000000000000000000000000000003
                #EXT-X-MAP:URI="init-1.mp4"
                #EXTINF:4,
                encrypted-1.m4s
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="init-2.mp4"
                #EXTINF:4,
                encrypted-2.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        for (url, plaintext) in zip(
            initializationURLs,
            initializationPlaintexts
        ) {
            HLSLiveURLProtocol.register(
                mediaResponse(
                    try aes128Encrypt(
                        plaintext,
                        key: key,
                        initializationVector: initializationVector
                    )
                ),
                for: url
            )
        }
        for (url, plaintext) in zip(segmentURLs, mediaPlaintexts) {
            HLSLiveURLProtocol.register(
                mediaResponse(
                    try aes128Encrypt(
                        plaintext,
                        key: key,
                        initializationVector: initializationVector
                    )
                ),
                for: url
            )
        }

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/initialization.mp4"
                )
            ) == initializationPlaintexts[0]
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/initialization-00001.mp4"
                )
            ) == initializationPlaintexts[1]
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/00000.m4s"
                )
            ) == mediaPlaintexts[0]
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/00001.m4s"
                )
            ) == mediaPlaintexts[1]
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                .count { $0 == keyURL } == 1
        )
    }

    @Test("invalid AES-128 key length fails atomically")
    func rejectsInvalidAES128KeyLength() async throws {
        try await assertAES128Failure(
            keyResponse: mediaResponse(Data(repeating: 0, count: 15)),
            expectedError: .invalidEncryptionKey
        )
    }

    @Test("AES-128 key status failures stay typed")
    func rejectsAES128KeyStatus() async throws {
        try await assertAES128Failure(
            keyResponse: HLSLiveURLProtocol.Response(
                statusCode: 403,
                data: Data(),
                headers: ["Content-Length": "0"]
            ),
            expectedError: .invalidEncryptionKeyResponseStatus(403)
        )
    }

    @Test("invalid AES-128 ciphertext fails atomically")
    func rejectsInvalidAES128Ciphertext() async throws {
        try await assertAES128Failure(
            keyResponse: mediaResponse(Data(repeating: 0x41, count: 16)),
            mediaData: Data(repeating: 0x42, count: 15),
            expectedError: .decryptionFailed
        )
    }

    @Test("SAMPLE-AES is rejected before key or media requests")
    func rejectsSampleAESBeforePersistence() async throws {
        let sourceURL = try url("https://media.example/sample-aes.m3u8")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset"
                #EXTINF:4,
                1.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )

        await #expect(
            throws: HLSLiveDVRError.unsupportedFeature(.encryptedMedia)
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: sourceURL, to: fixture.destinationURL)
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url) == [sourceURL]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("default external audio is retained behind a URL-free local master")
    func retainsDefaultExternalAudio() async throws {
        let masterURL = try url(
            "https://media.example/master-audio.m3u8"
        )
        let mediaURL = try url(
            "https://media.example/video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/audio.m3u8"
        )
        let videoSegmentURL = try url(
            "https://media.example/video.ts?token=video"
        )
        let audioSegmentURL = try url(
            "https://media.example/audio.aac?token=audio"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
                #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions",NAME="English CC",LANGUAGE="en",INSTREAM-ID="CC1"
                #EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS="avc1.4d401f,mp4a.40.2",HDCP-LEVEL=TYPE-0,AUDIO="audio",CLOSED-CAPTIONS="captions",ALLOWED-CPC="com.example.drm:HW"
                video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                video.ts?token=video
                #EXT-X-ENDLIST
                """
            ),
            for: mediaURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                audio.aac?token=audio
                #EXT-X-ENDLIST
                """
            ),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("video".utf8)),
            for: videoSegmentURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("audio".utf8)),
            for: audioSegmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(
            from: masterURL,
            to: fixture.destinationURL
        )

        #expect(receipt.entryPlaylistURL.lastPathComponent == "master.m3u8")
        #expect(receipt.playlistURL.lastPathComponent == "index.m3u8")
        #expect(receipt.tracks.map(\.kind) == [.primary, .audio])
        let audioTrack = try #require(receipt.tracks.last)
        let audioPlaylist = try String(
            contentsOf: receipt.directoryURL.appendingPathComponent(
                audioTrack.relativePlaylistPath
            ),
            encoding: .utf8
        )
        let master = try String(
            contentsOf: receipt.entryPlaylistURL,
            encoding: .utf8
        )
        let parsedMaster = try PlaylistResolver().resolve(
            master,
            relativeTo: receipt.entryPlaylistURL
        )
        #expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        #expect(master.contains("AUDIO=\"live-dvr-audio\""))
        #expect(master.contains(audioTrack.relativePlaylistPath))
        #expect(audioPlaylist.contains("resources/00000.aac"))
        #expect(!master.contains("media.example"))
        #expect(!master.contains("token="))
        #expect(!master.contains("CODECS"))
        #expect(!master.contains("HDCP-LEVEL"))
        #expect(!master.contains("ALLOWED-CPC"))
        #expect(parsedMaster.kind == .multivariant)
        #expect(parsedMaster.variants.first?.audioGroupID == "live-dvr-audio")
        #expect(parsedMaster.renditions.first?.name == "Stereo")
        #expect(parsedMaster.renditions.last?.name == "English CC")
        #expect(parsedMaster.renditions.last?.url == nil)
        #expect(!audioPlaylist.contains("media.example"))
        #expect(!audioPlaylist.contains("token="))
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url)
                == [
                    masterURL,
                    mediaURL,
                    audioPlaylistURL,
                    audioSegmentURL,
                    videoSegmentURL,
                ]
        )
    }

    @Test("external rendition gaps preserve their local timeline")
    func retainsExternalAudioGap() async throws {
        let masterURL = try url(
            "https://media.example/gap-audio-master.m3u8"
        )
        let videoPlaylistURL = try url(
            "https://media.example/gap-audio-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/gap-audio.m3u8"
        )
        let videoURLs = try [1, 2, 3].map {
            try url("https://media.example/gap-video-\($0).ts")
        }
        let audioURLs = try [1, 2, 3].map {
            try url("https://media.example/gap-audio-\($0).aac")
        }
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="gap-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                gap-audio-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                gap-video-1.ts
                #EXTINF:4,
                gap-video-2.ts
                #EXTINF:4,
                gap-video-3.ts
                #EXT-X-ENDLIST
                """
            ),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-GAP
                #EXTINF:4,
                gap-audio-1.aac
                #EXT-X-GAP
                #EXTINF:4,
                gap-audio-2.aac
                #EXT-X-GAP
                #EXTINF:4,
                gap-audio-3.aac
                #EXT-X-ENDLIST
                """
            ),
            for: audioPlaylistURL
        )
        for (index, videoURL) in videoURLs.enumerated() {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("video-\(index + 1)".utf8)),
                for: videoURL
            )
        }
        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(receipt.gapCount == 0)
        let audioTrack = try #require(
            receipt.tracks.first { $0.kind == .audio }
        )
        let audioPlaylist = try String(
            contentsOf: receipt.directoryURL.appendingPathComponent(
                audioTrack.relativePlaylistPath
            ),
            encoding: .utf8
        )
        #expect(
            audioPlaylist.contains(
                "#EXT-X-GAP\n#EXTINF:4.0,\nresources/gap-00001.aac"
            )
        )
        #expect(
            audioPlaylist.components(separatedBy: "#EXT-X-GAP").count
                - 1 == 3
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(audioURLs.allSatisfy { !requests.contains($0) })
        #expect(
            !FileManager.default.fileExists(
                atPath: receipt.directoryURL
                    .appendingPathComponent(
                        audioTrack.relativePlaylistPath
                    )
                    .deletingLastPathComponent()
                    .appendingPathComponent("resources/gap-00001.aac")
                    .path
            )
        )
    }

    @Test("external fMP4 renditions preserve initialization map rotation")
    func recordsRenditionInitializationMapRotation() async throws {
        let masterURL = try url(
            "https://media.example/rendition-map-master.m3u8"
        )
        let videoPlaylistURL = try url(
            "https://media.example/rendition-map-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/rendition-map-audio.m3u8"
        )
        let firstMapURL = try url(
            "https://media.example/rendition-map-a.mp4"
        )
        let secondMapURL = try url(
            "https://media.example/rendition-map-b.mp4"
        )
        let videoURLs = try [1, 2].map {
            try url("https://media.example/rendition-video-\($0).ts")
        }
        let audioURLs = try [1, 2].map {
            try url("https://media.example/rendition-audio-\($0).m4s")
        }
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="rendition-map-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                rendition-map-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                rendition-video-1.ts
                #EXTINF:4,
                rendition-video-2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-MAP:URI="rendition-map-a.mp4"
                #EXTINF:4,
                rendition-audio-1.m4s
                #EXT-X-DISCONTINUITY
                #EXT-X-MAP:URI="rendition-map-b.mp4"
                #EXTINF:4,
                rendition-audio-2.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-a".utf8)),
            for: firstMapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("map-b".utf8)),
            for: secondMapURL
        )
        for (index, audioURL) in audioURLs.enumerated() {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("audio-\(index + 1)".utf8)),
                for: audioURL
            )
        }
        for (index, videoURL) in videoURLs.enumerated() {
            HLSLiveURLProtocol.register(
                mediaResponse(Data("video-\(index + 1)".utf8)),
                for: videoURL
            )
        }

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: masterURL, to: fixture.destinationURL)

        let audioTrack = try #require(
            receipt.tracks.first { $0.kind == .audio }
        )
        let audioPlaylist = try String(
            contentsOf: receipt.directoryURL.appendingPathComponent(
                audioTrack.relativePlaylistPath
            ),
            encoding: .utf8
        )
        let mapLines = audioPlaylist.split(separator: "\n").filter {
            $0.hasPrefix("#EXT-X-MAP:")
        }
        #expect(
            mapLines == [
                "#EXT-X-MAP:URI=\"resources/initialization.mp4\"",
                "#EXT-X-MAP:URI=\"resources/initialization-00001.mp4\"",
            ]
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.count { $0 == firstMapURL } == 1)
        #expect(requests.count { $0 == secondMapURL } == 1)
        #expect(!audioPlaylist.contains("media.example"))
    }

    @Test("primary and external renditions share the in-memory AES key cache")
    func sharesAES128KeyAcrossRenditions() async throws {
        let masterURL = try url("https://media.example/aes-master.m3u8")
        let videoPlaylistURL = try url(
            "https://media.example/aes-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/aes-audio.m3u8"
        )
        let keyURL = try url("https://media.example/shared.key")
        let videoURL = try url("https://media.example/aes-video.ts")
        let audioURL = try url("https://media.example/aes-audio.aac")
        let key = Data(repeating: 0x71, count: 16)
        let videoPlaintext = Data("encrypted video".utf8)
        let audioPlaintext = Data("encrypted audio".utf8)
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="aes-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                aes-video.m3u8
                """
            ),
            for: masterURL
        )
        let encryptedPlaylist: (String) -> String = { resource in
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-KEY:METHOD=AES-128,URI="shared.key"
            #EXTINF:4,
            \(resource)
            #EXT-X-ENDLIST
            """
        }
        HLSLiveURLProtocol.register(
            playlistResponse(encryptedPlaylist("aes-video.ts")),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(encryptedPlaylist("aes-audio.aac")),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    videoPlaintext,
                    key: key,
                    initializationVector: sequenceIV(1)
                )
            ),
            for: videoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    audioPlaintext,
                    key: key,
                    initializationVector: sequenceIV(1)
                )
            ),
            for: audioURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                .count { $0 == keyURL } == 1
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/00000.ts"
                )
            ) == videoPlaintext
        )
        let audioTrack = try #require(
            receipt.tracks.first(where: { $0.kind == .audio })
        )
        let audioDirectory = String(
            audioTrack.relativePlaylistPath.dropLast(
                "/index.m3u8".count
            )
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    audioDirectory + "/resources/00000.aac"
                )
            ) == audioPlaintext
        )
    }

    @Test("program time and standard Date Ranges survive local packaging")
    func retainsTimelineMetadata() async throws {
        let sourceURL = try url("https://media.example/timeline.m3u8")
        let firstURL = try url("https://media.example/10.ts")
        let secondURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:00.000Z
                #EXT-X-DATERANGE:ID="chapter-1",CLASS="chapter",START-DATE="2026-08-30T00:00:01.000Z",DURATION=5,PLANNED-DURATION=6,CUE="ONCE"
                #EXTINF:4,
                10.ts
                #EXTINF:4,
                11.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)
        let localContents = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        let localPlaylist = try PlaylistResolver().resolve(
            localContents,
            relativeTo: receipt.playlistURL
        )

        #expect(localPlaylist.programDateTimes.count == 2)
        #expect(localPlaylist.dateRanges.count == 1)
        #expect(localPlaylist.dateRanges[0].id == "chapter-1")
        #expect(localPlaylist.dateRanges[0].duration == 5)
        #expect(localPlaylist.dateRanges[0].plannedDuration == 6)
        #expect(localPlaylist.dateRanges[0].cues == [.once])
        #expect(
            localPlaylist.programDateTimes[1].date
                .timeIntervalSince(
                    localPlaylist.programDateTimes[0].date
                ) == 4
        )
    }

    @Test("recorded Date Ranges survive later live-window eviction")
    func retainsEvictedTimelineMetadata() async throws {
        let sourceURL = try url(
            "https://media.example/rolling-timeline.m3u8"
        )
        let reloadURL = try url(
            "https://media.example/rolling-timeline.m3u8?_HLS_msn=2"
        )
        let firstURL = try url("https://media.example/rolling-1.ts")
        let secondURL = try url("https://media.example/rolling-2.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:00.000Z
                #EXT-X-DATERANGE:ID="chapter-1",CLASS="chapter",START-DATE="2026-08-30T00:00:00.000Z",DURATION=4
                #EXTINF:4,
                rolling-1.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:04.000Z
                #EXTINF:4,
                rolling-2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: firstURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("second".utf8)),
            for: secondURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)
        let localContents = try String(
            contentsOf: receipt.playlistURL,
            encoding: .utf8
        )
        let localPlaylist = try PlaylistResolver().resolve(
            localContents,
            relativeTo: receipt.playlistURL
        )
        let lines = localContents.components(separatedBy: .newlines)
        let programDateIndex = try #require(
            lines.firstIndex(where: {
                $0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
            })
        )
        let dateRangeIndex = try #require(
            lines.firstIndex(where: {
                $0.hasPrefix("#EXT-X-DATERANGE:")
            })
        )

        #expect(localPlaylist.dateRanges.map(\.id) == ["chapter-1"])
        #expect(programDateIndex < dateRangeIndex)
    }

    @Test("redacted Date Range extension values fail before media persistence")
    func rejectsUnrepresentableTimelineMetadata() async throws {
        let sourceURL = try url(
            "https://media.example/custom-timeline.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-PROGRAM-DATE-TIME:2026-08-30T00:00:00.000Z
                #EXT-X-DATERANGE:ID="custom",START-DATE="2026-08-30T00:00:00.000Z",SCTE35-OUT=0xFC
                #EXTINF:4,
                media.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )

        await #expect(
            throws: HLSLiveDVRError.unsupportedFeature(
                .unrepresentableTimelineMetadata
            )
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: sourceURL, to: fixture.destinationURL)
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
                == [sourceURL]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("external rendition must cover the retained primary timeline")
    func rejectsIncompleteExternalRenditionAtomically() async throws {
        let masterURL = try url("https://media.example/short-master.m3u8")
        let videoPlaylistURL = try url(
            "https://media.example/short-video.m3u8"
        )
        let audioPlaylistURL = try url(
            "https://media.example/short-audio.m3u8"
        )
        let videoURL = try url("https://media.example/short-video.ts")
        let audioURL = try url("https://media.example/short-audio.aac")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="short-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                short-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                short-video.ts
                #EXT-X-ENDLIST
                """
            ),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:1
                #EXTINF:1,
                short-audio.aac
                #EXT-X-ENDLIST
                """
            ),
            for: audioPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("video".utf8)),
            for: videoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("audio".utf8)),
            for: audioURL
        )

        await #expect(
            throws: HLSLiveDVRError.unsupportedFeature(
                .incompleteExternalRendition
            )
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: masterURL, to: fixture.destinationURL)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    @Test("preferred subtitle languages retain imported-variable playlists")
    func retainsPreferredSubtitleRenditionsWithImportedVariables() async throws {
        let masterURL = try url("https://media.example/subtitles-master.m3u8")
        let videoPlaylistURL = try url(
            "https://media.example/subtitles-video.m3u8"
        )
        let koreanPlaylistURL = try url(
            "https://media.example/ko.m3u8"
        )
        let englishPlaylistURL = try url(
            "https://media.example/en.m3u8"
        )
        let videoURL = try url("https://media.example/subtitles-video.ts")
        let koreanURL = try url("https://media.example/ko.vtt")
        let englishURL = try url("https://media.example/en.vtt")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:8
                #EXT-X-DEFINE:NAME="KO_RESOURCE",VALUE="ko.vtt"
                #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",AUTOSELECT=YES,URI="en.m3u8"
                #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="ko.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"
                subtitles-video.m3u8
                """
            ),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                subtitles-video.ts
                #EXT-X-ENDLIST
                """
            ),
            for: videoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:8
                #EXT-X-DEFINE:IMPORT="KO_RESOURCE"
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                {$KO_RESOURCE}
                #EXT-X-ENDLIST
                """
            ),
            for: koreanPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXTINF:4,
                en.vtt
                #EXT-X-ENDLIST
                """
            ),
            for: englishPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("video".utf8)),
            for: videoURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("WEBVTT\nko".utf8)),
            for: koreanURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("WEBVTT\nen".utf8)),
            for: englishURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow,
            renditions: HLSLiveDVRRenditionPack(
                audio: .disabled,
                subtitles: .preferredLanguages(["ko-KR", "en"])
            )
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(
            receipt.tracks.map(\.kind)
                == [.primary, .subtitles, .subtitles]
        )
        #expect(receipt.tracks.dropFirst().map(\.language) == ["ko", "en"])
        let master = try String(
            contentsOf: receipt.entryPlaylistURL,
            encoding: .utf8
        )
        #expect(
            master.components(separatedBy: "#EXT-X-MEDIA:TYPE=SUBTITLES")
                .count - 1 == 2
        )
        #expect(!master.contains("KO_RESOURCE"))
        #expect(!master.contains("media.example"))
    }

    @Test("subtitle provenance is consistent with offline selection")
    func selectsSubtitleProvenance() throws {
        let masterURL = try url(
            "https://media.example/provenance-master.m3u8"
        )
        let mediaURL = try url(
            "https://media.example/provenance-video.m3u8"
        )
        let master = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Authored",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="authored.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Generated",LANGUAGE="en",AUTOSELECT=YES,CHARACTERISTICS="public.machine-generated",URI="generated.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Translated",LANGUAGE="en",AUTOSELECT=YES,CHARACTERISTICS="public.machine-generated,public.translation,example.custom",URI="translated.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"
            provenance-video.m3u8
            """,
            relativeTo: masterURL
        )
        let media = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            media.ts
            """,
            relativeTo: mediaURL
        )
        let snapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: master.variants.first,
            availableRenditions: master.renditions,
            pathwayID: nil,
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )

        let preferred = try HLSLiveDVRRenditionSelector.select(
            from: snapshot,
            pack: HLSLiveDVRRenditionPack(
                audio: .disabled,
                subtitles: .preferredLanguages(["en"]),
                subtitleProvenance: HLSSubtitleProvenancePolicy(
                    translation: .preferred
                )
            )
        )
        let preferredTrack = try #require(preferred.external.first?.track)
        #expect(preferredTrack.name == "Translated")
        #expect(preferredTrack.isMachineGenerated)
        #expect(preferredTrack.isTranslated)
        #expect(
            preferredTrack.mediaCharacteristics
                == [
                    .machineGenerated,
                    .translation,
                    HLSMediaCharacteristic(rawValue: "example.custom"),
                ]
        )

        let excluded = try HLSLiveDVRRenditionSelector.select(
            from: snapshot,
            pack: HLSLiveDVRRenditionPack(
                audio: .disabled,
                subtitles: .all,
                subtitleProvenance: HLSSubtitleProvenancePolicy(
                    translation: .excluded
                )
            )
        )
        #expect(
            excluded.external.map(\.track.name)
                == ["Authored", "Generated"]
        )
    }

    @Test("stable rendition identity survives Content Steering failover")
    func retainsRenditionAcrossContentSteeringFailover() async throws {
        let masterURL = try url("https://media.example/dvr-steered.m3u8")
        let steeringURL = try url("https://media.example/dvr-steering.json")
        let primaryVideoURL = try url("https://media.example/a-video.m3u8")
        let primaryReloadURL = try url(
            "https://media.example/a-video.m3u8?_HLS_msn=2"
        )
        let primaryAudioURL = try url("https://media.example/a-audio.m3u8")
        let fallbackVideoURL = try url(
            "https://media.example/b-video.m3u8?_HLS_msn=1"
        )
        let fallbackAudioURL = try url("https://media.example/b-audio.m3u8")
        let fallbackVideoSegmentURL = try url(
            "https://media.example/b-video-2.ts"
        )
        let fallbackAudioSegmentURL = try url(
            "https://media.example/b-audio-2.aac"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-CONTENT-STEERING:SERVER-URI="dvr-steering.json",PATHWAY-ID="A"
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",STABLE-RENDITION-ID="audio-main",DEFAULT=YES,URI="a-audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720,CODECS="avc1.4d401f",AUDIO="audio",STABLE-VARIANT-ID="video-main",PATHWAY-ID="A"
                a-video.m3u8
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
                      "PATHWAY-PRIORITY": ["A", "B"],
                      "PATHWAY-CLONES": [{
                        "BASE-ID": "A",
                        "ID": "B",
                        "URI-REPLACEMENT": {
                          "PER-VARIANT-URIS": {
                            "video-main": "https://media.example/b-video.m3u8"
                          },
                          "PER-RENDITION-URIS": {
                            "audio-main": "https://media.example/b-audio.m3u8"
                          }
                        }
                      }]
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: steeringURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                a-video-1.ts
                #EXT-X-RENDITION-REPORT:URI="b-video.m3u8",LAST-MSN=1
                """
            ),
            for: primaryVideoURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                a-audio-1.aac
                """
            ),
            for: primaryAudioURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:2
                #EXTINF:4,
                b-video-2.ts
                #EXT-X-ENDLIST
                """
            ),
            for: fallbackVideoURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXTINF:4,
                b-audio-1.aac
                #EXTINF:4,
                b-audio-2.aac
                #EXT-X-ENDLIST
                """
            ),
            for: fallbackAudioURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("fallback-video".utf8)),
            for: fallbackVideoSegmentURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("fallback-audio".utf8)),
            for: fallbackAudioSegmentURL
        )

        let client = HLSLivePlaylistClient(
            session: fixture.session,
            configuration: .advanced(
                variantSelectionPolicy: .highestQuality,
                contentSteering: HLSContentSteeringPack()
            )
        )
        let receipt = try await HLSLiveDVRRecorder(
            client: client,
            configuration: .advanced(
                limits: HLSLiveDVRLimitPack(
                    maximumDuration: 60,
                    maximumSegmentCount: 20,
                    maximumMediaResourceBytes: 1_024,
                    maximumTotalMediaBytes: 4_096
                ),
                startPosition: .nextCompletedSegment
            )
        ).record(from: masterURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.tracks.last?.stableID == "audio-main")
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(primaryReloadURL))
        #expect(requests.contains(fallbackVideoURL))
        #expect(requests.contains(fallbackAudioURL))
        #expect(requests.contains(fallbackVideoSegmentURL))
        #expect(requests.contains(fallbackAudioSegmentURL))
    }

    @Test("Content Steering rejects an unreferenced stable rendition")
    func rejectsUnreferencedStableRendition() throws {
        let sourceURL = try url("https://media.example/source-master.m3u8")
        let fallbackURL = try url(
            "https://media.example/fallback-master.m3u8"
        )
        let mediaURL = try url("https://media.example/media.m3u8")
        let source = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-a",NAME="English",STABLE-RENDITION-ID="audio-main",DEFAULT=YES,URI="a.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio-a",STABLE-VARIANT-ID="video-main",PATHWAY-ID="A"
            a-video.m3u8
            """,
            relativeTo: sourceURL
        )
        let fallback = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-a",NAME="Unreferenced",STABLE-RENDITION-ID="audio-main",DEFAULT=YES,URI="wrong.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-b",NAME="Current",STABLE-RENDITION-ID="audio-current",DEFAULT=YES,URI="current.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio-b",STABLE-VARIANT-ID="video-main",PATHWAY-ID="B"
            b-video.m3u8
            """,
            relativeTo: fallbackURL
        )
        let media = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            media.ts
            """,
            relativeTo: mediaURL
        )
        let sourceSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: source.variants.first,
            availableRenditions: source.renditions,
            pathwayID: "A",
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )
        let fallbackSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: fallback.variants.first,
            availableRenditions: fallback.renditions,
            pathwayID: "B",
            generation: 1,
            isDeltaUpdate: false,
            isEnded: false
        )
        let selection = try HLSLiveDVRRenditionSelector.select(
            from: sourceSnapshot,
            pack: HLSLiveDVRRenditionPack()
        )
        let selected = try #require(selection.external.first)

        #expect(
            throws: HLSLiveDVRError.unsupportedFeature(
                .incompleteExternalRendition
            )
        ) {
            try selected.source(
                in: fallbackSnapshot,
                initialPathwayID: "A"
            )
        }
    }

    @Test("Content Steering retains only proven in-band captions")
    func retainsOnlyProvenInBandCaptions() throws {
        let sourceURL = try url("https://media.example/source-master.m3u8")
        let fallbackURL = try url(
            "https://media.example/fallback-master.m3u8"
        )
        let mediaURL = try url("https://media.example/media.m3u8")
        let source = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-a",NAME="Stable",STABLE-RENDITION-ID="captions-main",INSTREAM-ID="CC1"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-a",NAME="Declared",INSTREAM-ID="CC2"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CLOSED-CAPTIONS="captions-a",STABLE-VARIANT-ID="video-main",PATHWAY-ID="A"
            a-video.m3u8
            """,
            relativeTo: sourceURL
        )
        let fallback = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-b",NAME="Stable fallback",STABLE-RENDITION-ID="captions-main",INSTREAM-ID="CC1"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-b",NAME="Declared",INSTREAM-ID="CC2"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions-a",NAME="Unreferenced",STABLE-RENDITION-ID="captions-main",INSTREAM-ID="CC3"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CLOSED-CAPTIONS="captions-b",STABLE-VARIANT-ID="video-main",PATHWAY-ID="B"
            b-video.m3u8
            """,
            relativeTo: fallbackURL
        )
        let media = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            media.ts
            """,
            relativeTo: mediaURL
        )
        let sourceSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: source.variants.first,
            availableRenditions: source.renditions,
            pathwayID: "A",
            generation: 0,
            isDeltaUpdate: false,
            isEnded: false
        )
        let fallbackSnapshot = HLSLivePlaylistSnapshot(
            playlist: media,
            segments: [],
            partialSegments: [],
            dateRanges: [],
            selectedVariant: fallback.variants.first,
            availableRenditions: fallback.renditions,
            pathwayID: "B",
            generation: 1,
            isDeltaUpdate: false,
            isEnded: false
        )
        let selection = try HLSLiveDVRRenditionSelector.select(
            from: sourceSnapshot,
            pack: HLSLiveDVRRenditionPack()
        )

        let retained = HLSLiveDVRRenditionSelector.retainedClosedCaptions(
            selection.inBandClosedCaptions,
            in: fallbackSnapshot,
            initialPathwayID: "A"
        )

        #expect(retained.count == 1)
        #expect(retained.first?.stableID == "captions-main")
        #expect(retained.first?.groupID == "captions-b")
        #expect(retained.first?.instreamID == "CC1")
    }

    @Test("independent LL-HLS parts promote without downloading the parent")
    func promotesIndependentParts() async throws {
        let sourceURL = try url("https://media.example/parts.m3u8")
        let reloadURL = try url(
            "https://media.example/parts.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(partialPlaylist()),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(completedPartialPlaylist()),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )

        var stagedProgress: [HLSLiveDVRProgress] = []
        var completedReceipt: HLSLiveDVRReceipt?
        for try await event in recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).events(from: sourceURL, to: fixture.destinationURL) {
            switch event {
            case .progress(let progress):
                if progress.stagedPartCount > 0 {
                    stagedProgress.append(progress)
                }
            case .completed(let receipt):
                completedReceipt = receipt
            }
        }
        let receipt = try #require(completedReceipt)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.promotedPartCount == 2)
        #expect(receipt.mediaByteCount == 6)
        #expect(stagedProgress.map(\.stagedPartCount) == [1, 2])
        #expect(stagedProgress.map(\.stagedPartByteCount) == [3, 6])
        #expect(stagedProgress.map(\.stagedPartDuration) == [2, 4])
        #expect(
            try Data(
                contentsOf: fixture.destinationURL
                    .appendingPathComponent("resources/00000.ts")
            ) == Data("onetwo".utf8)
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(firstPartURL))
        #expect(requests.contains(secondPartURL))
        #expect(!requests.contains(parentURL))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL
                    .appendingPathComponent("partial").path
            )
        )
    }

    @Test("a completed GAP discards staged LL-HLS parts")
    func discardsStagedPartsForGapParent() async throws {
        let sourceURL = try url("https://media.example/gap-parts.m3u8")
        let reloadURL = try url(
            "https://media.example/gap-parts.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(partialPlaylist()),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                partialPlaylist()
                    + """

                    #EXT-X-GAP
                    #EXTINF:4,
                    11.ts
                    #EXT-X-ENDLIST
                    """
            ),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.segmentCount == 1)
        #expect(receipt.gapCount == 1)
        #expect(receipt.recordedDuration == 4)
        #expect(receipt.mediaByteCount == 0)
        #expect(receipt.promotedPartCount == 0)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(firstPartURL))
        #expect(requests.contains(secondPartURL))
        #expect(!requests.contains(parentURL))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL
                    .appendingPathComponent("partial").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL
                    .appendingPathComponent("resources/gap-00000.ts").path
            )
        )
    }

    @Test("LL-HLS part byte ranges remain exact before promotion")
    func promotesExactPartByteRanges() async throws {
        let sourceURL = try url("https://media.example/ranged-parts.m3u8")
        let reloadURL = try url(
            "https://media.example/ranged-parts.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let partURL = try url("https://media.example/parts.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:9
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:10
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=4
                #EXT-X-PART-INF:PART-TARGET=2
                #EXTINF:4,
                10.ts
                #EXT-X-PART:DURATION=2,URI="parts.ts",BYTERANGE="3@0",INDEPENDENT=YES
                #EXT-X-PART:DURATION=2,URI="parts.ts",BYTERANGE="3@3"
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(completedPlaylistWithoutParts()),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 206,
                data: Data("one".utf8),
                headers: [
                    "Content-Length": "3",
                    "Content-Range": "bytes 0-2/6",
                ]
            ),
            for: partURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 206,
                data: Data("two".utf8),
                headers: [
                    "Content-Length": "3",
                    "Content-Range": "bytes 3-5/6",
                ]
            ),
            for: partURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 2)
        #expect(
            try Data(
                contentsOf: fixture.destinationURL
                    .appendingPathComponent("resources/00000.ts")
            ) == Data("onetwo".utf8)
        )
        let partRequests = HLSLiveURLProtocol.capturedRequests().filter {
            $0.url == partURL
        }
        #expect(
            partRequests.map {
                $0.value(forHTTPHeaderField: "Range")
            } == ["bytes=0-2", "bytes=3-5"]
        )
        #expect(
            partRequests.allSatisfy {
                $0.value(forHTTPHeaderField: "Accept-Encoding")
                    == "identity"
            }
        )
        #expect(
            !HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url).contains(parentURL)
        )
    }

    @Test("a confirmed PART preload is reused without a second request")
    func reusesConfirmedPartPreload() async throws {
        let sourceURL = try url("https://media.example/preload-part.m3u8")
        let firstReloadURL = try url(
            "https://media.example/preload-part.m3u8?_HLS_msn=11&_HLS_part=1"
        )
        let secondReloadURL = try url(
            "https://media.example/preload-part.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        let requestRecorder = HLSLiveDVRRequestRecorder()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PART:DURATION=1,URI="11.0.ts",INDEPENDENT=YES
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.1.ts"
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PART:DURATION=1,URI="11.0.ts",INDEPENDENT=YES
                #EXT-X-PART:DURATION=1,URI="11.1.ts"
                """,
                delay: 0.05
            ),
            for: firstReloadURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PART:DURATION=1,URI="11.0.ts",INDEPENDENT=YES
                #EXT-X-PART:DURATION=1,URI="11.1.ts"
                #EXTINF:2,
                11.ts
                #EXT-X-ENDLIST
                """,
                delay: 0.05
            ),
            for: secondReloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )
        var progressSnapshots: [HLSLiveDVRProgress] = []
        var completedReceipt: HLSLiveDVRReceipt?
        for try await event in recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent),
            preloading: HLSLiveDVRPreloadPack(
                policy: .unencryptedMedia
            ),
            requestPolicy: HLSRequestPolicy(
                eventObservers: [requestRecorder]
            )
        ).events(from: sourceURL, to: fixture.destinationURL) {
            switch event {
            case .progress(let progress):
                progressSnapshots.append(progress)
            case .completed(let receipt):
                completedReceipt = receipt
            }
        }
        let receipt = try #require(completedReceipt)

        #expect(receipt.promotedPartCount == 2)
        #expect(
            HLSLiveURLProtocol.capturedRequests().filter {
                $0.url == secondPartURL
            }.count == 1
        )
        #expect(
            !HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url).contains(parentURL)
        )
        #expect(
            await requestRecorder.purposes().filter {
                $0 == .mediaPreloadHint
            }.count == 1
        )
        let statistics = receipt.preloadStatistics.partialSegments
        #expect(statistics.requestCount == 1)
        #expect(statistics.completedCount == 1)
        #expect(statistics.confirmedCount == 1)
        #expect(statistics.reuseCount == 1)
        #expect(statistics.missCount == 1)
        #expect(statistics.failureCount == 0)
        #expect(statistics.cancellationCount == 0)
        #expect(statistics.discardCount == 0)
        #expect(statistics.transferredByteCount == 3)
        #expect(statistics.reusedByteCount == 3)
        #expect(statistics.discardedByteCount == 0)
        #expect(
            progressSnapshots.last?.preloadStatistics
                == receipt.preloadStatistics
        )
    }

    @Test("a failed PART preload falls back to the ordinary request")
    func fallsBackAfterPartPreloadFailure() async throws {
        let sourceURL = try url(
            "https://media.example/preload-fallback.m3u8"
        )
        let firstReloadURL = try url(
            "https://media.example/preload-fallback.m3u8?_HLS_msn=11&_HLS_part=1"
        )
        let secondReloadURL = try url(
            "https://media.example/preload-fallback.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PART:DURATION=1,URI="11.0.ts",INDEPENDENT=YES
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.1.ts"
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PART:DURATION=1,URI="11.0.ts",INDEPENDENT=YES
                #EXT-X-PART:DURATION=1,URI="11.1.ts"
                """,
                delay: 0.05
            ),
            for: firstReloadURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PART:DURATION=1,URI="11.0.ts",INDEPENDENT=YES
                #EXT-X-PART:DURATION=1,URI="11.1.ts"
                #EXTINF:2,
                11.ts
                #EXT-X-ENDLIST
                """
            ),
            for: secondReloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 503,
                data: Data(),
                headers: ["Content-Type": "application/octet-stream"]
            ),
            for: secondPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent),
            preloading: HLSLiveDVRPreloadPack(
                policy: .unencryptedMedia
            )
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 2)
        #expect(
            HLSLiveURLProtocol.capturedRequests().filter {
                $0.url == secondPartURL
            }.count == 2
        )
        let statistics = receipt.preloadStatistics.partialSegments
        #expect(statistics.requestCount == 1)
        #expect(statistics.completedCount == 0)
        #expect(statistics.confirmedCount == 1)
        #expect(statistics.reuseCount == 0)
        #expect(statistics.missCount == 2)
        #expect(statistics.failureCount == 1)
        #expect(statistics.cancellationCount == 0)
        #expect(statistics.discardCount == 1)
        #expect(statistics.transferredByteCount == 0)
        #expect(statistics.reusedByteCount == 0)
        #expect(statistics.discardedByteCount == 0)
    }

    @Test("a changed discontinuity rejects a hinted PART")
    func rejectsPreloadAcrossDiscontinuity() async throws {
        let hintPlaylistURL = try url(
            "https://media.example/preload-hint.m3u8"
        )
        let actualPlaylistURL = try url(
            "https://media.example/preload-actual.m3u8"
        )
        let partURL = try url("https://media.example/11.0.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.0.ts"
                """
            ),
            for: hintPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-DISCONTINUITY
                #EXT-X-PART:DURATION=1,URI="11.0.ts",INDEPENDENT=YES
                """
            ),
            for: actualPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("hinted".utf8)),
            for: partURL
        )
        let configuration = HLSLiveDVRConfiguration.advanced(
            parts: HLSLiveDVRPartPack(policy: .independent),
            preloading: HLSLiveDVRPreloadPack(
                policy: .unencryptedMedia
            )
        )
        let client = HLSLivePlaylistClient(session: fixture.session)
        let writer = HLSLiveDVRResourceWriter(
            client: client.resourceClient,
            configuration: configuration
        )
        let workspace = try HLSLiveDVRWorkspace.make(
            for: fixture.destinationURL
        )
        let resourceContext = writer.makeContext(workspace: workspace)
        let coordinator = try #require(
            writer.makePreloadCoordinator(
                workspace: workspace,
                context: resourceContext
            )
        )
        let hintSnapshot = try await client.snapshot(
            from: hintPlaylistURL
        )
        await coordinator.update(from: hintSnapshot)
        for _ in 0..<100
        where !HLSLiveURLProtocol.capturedRequests().contains(where: {
            $0.url == partURL
        }) {
            await Task.yield()
        }
        let actualSnapshot = try await client.snapshot(
            from: actualPlaylistURL
        )
        await coordinator.update(from: actualSnapshot)
        let actualPart = try #require(
            actualSnapshot.partialSegments.first
        )
        let destinationURL = workspace.directoryURL
            .appendingPathComponent("actual.part")

        #expect(
            await coordinator.consume(
                actualPart,
                to: destinationURL,
                maximumRetainedBytes: 1_024
            ) == nil
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationURL.path
            )
        )
        let statistics = await coordinator.cancelAll().partialSegments
        #expect(statistics.requestCount == 1)
        #expect(statistics.confirmedCount == 0)
        #expect(statistics.reuseCount == 0)
        #expect(statistics.missCount == 1)
        #expect(statistics.discardCount == 1)
        #expect(
            (statistics.transferredByteCount == 6 ? 1 : 0)
                + statistics.failureCount
                + statistics.cancellationCount == 1
        )
        #expect(
            statistics.completedCount
                == (statistics.transferredByteCount == 6 ? 1 : 0)
        )
        #expect(
            statistics.transferredByteCount
                == statistics.discardedByteCount
        )
    }

    @Test("an open MAP hint may confirm an exact PART context")
    func reusesPartAfterOpenMapRangeConfirmation() async throws {
        let hintPlaylistURL = try url(
            "https://media.example/open-map-hint.m3u8"
        )
        let actualPlaylistURL = try url(
            "https://media.example/open-map-actual.m3u8"
        )
        let partURL = try url("https://media.example/11.0.m4s")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PRELOAD-HINT:TYPE=MAP,URI="init.mp4",BYTERANGE-START=512
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.0.m4s"
                """
            ),
            for: hintPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-MAP:URI="init.mp4",BYTERANGE="4@512"
                #EXT-X-PART:DURATION=1,URI="11.0.m4s",INDEPENDENT=YES
                """
            ),
            for: actualPlaylistURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("hinted".utf8)),
            for: partURL
        )
        let configuration = HLSLiveDVRConfiguration.advanced(
            parts: HLSLiveDVRPartPack(policy: .independent),
            preloading: HLSLiveDVRPreloadPack(
                policy: .unencryptedMedia
            )
        )
        let client = HLSLivePlaylistClient(session: fixture.session)
        let writer = HLSLiveDVRResourceWriter(
            client: client.resourceClient,
            configuration: configuration
        )
        let workspace = try HLSLiveDVRWorkspace.make(
            for: fixture.destinationURL
        )
        let resourceContext = writer.makeContext(workspace: workspace)
        let coordinator = try #require(
            writer.makePreloadCoordinator(
                workspace: workspace,
                context: resourceContext
            )
        )
        let hintSnapshot = try await client.snapshot(
            from: hintPlaylistURL
        )
        await coordinator.update(from: hintSnapshot)
        let actualSnapshot = try await client.snapshot(
            from: actualPlaylistURL
        )
        await coordinator.update(from: actualSnapshot)
        await coordinator.update(from: hintSnapshot)
        await coordinator.update(from: actualSnapshot)
        let part = try #require(actualSnapshot.partialSegments.first)
        let destinationURL = workspace.directoryURL
            .appendingPathComponent("confirmed.part")

        #expect(
            await coordinator.consume(
                part,
                to: destinationURL,
                maximumRetainedBytes: 1_024
            ) == 6
        )
        #expect(
            try Data(contentsOf: destinationURL)
                == Data("hinted".utf8)
        )
        let statistics = await coordinator.cancelAll().partialSegments
        #expect(statistics.requestCount == 1)
        #expect(statistics.completedCount == 1)
        #expect(statistics.confirmedCount == 1)
        #expect(statistics.reuseCount == 1)
        #expect(statistics.missCount == 0)
        #expect(statistics.transferredByteCount == 6)
        #expect(statistics.reusedByteCount == 6)
    }

    @Test("cancelling preloads removes recording-scoped temporary files")
    func cancellationRemovesPreloadFiles() async throws {
        let playlistURL = try url(
            "https://media.example/preload-cancellation.m3u8"
        )
        let partURL = try url("https://media.example/11.0.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:1
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.0.ts"
                """
            ),
            for: playlistURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 200,
                data: Data("pending".utf8),
                headers: ["Content-Type": "application/octet-stream"],
                delay: 0.1
            ),
            for: partURL
        )
        let configuration = HLSLiveDVRConfiguration.advanced(
            parts: HLSLiveDVRPartPack(policy: .independent),
            preloading: HLSLiveDVRPreloadPack(
                policy: .unencryptedMedia
            )
        )
        let client = HLSLivePlaylistClient(session: fixture.session)
        let writer = HLSLiveDVRResourceWriter(
            client: client.resourceClient,
            configuration: configuration
        )
        let workspace = try HLSLiveDVRWorkspace.make(
            for: fixture.destinationURL
        )
        let coordinator = try #require(
            writer.makePreloadCoordinator(
                workspace: workspace,
                context: writer.makeContext(workspace: workspace)
            )
        )
        let snapshot = try await client.snapshot(from: playlistURL)
        await coordinator.update(from: snapshot)
        for _ in 0..<100
        where !HLSLiveURLProtocol.capturedRequests().contains(where: {
            $0.url == partURL
        }) {
            await Task.yield()
        }

        let statistics = await coordinator.cancelAll().partialSegments

        #expect(
            !FileManager.default.fileExists(
                atPath: workspace.directoryURL
                    .appendingPathComponent("preload").path
            )
        )
        #expect(statistics.requestCount == 1)
        #expect(statistics.reuseCount == 0)
        #expect(statistics.cancellationCount == 1)
        #expect(statistics.discardCount == 1)
    }

    @Test("encrypted edge MAP metadata is not treated as clear media")
    func doesNotExposeEncryptedEdgeMapAsClearMedia() async throws {
        let sourceURL = try url(
            "https://media.example/encrypted-edge-map.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-SERVER-CONTROL:PART-HOLD-BACK=2
                #EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x00000000000000000000000000000001
                #EXT-X-MAP:URI="init.mp4"
                #EXT-X-PART:DURATION=1,URI="10.0.m4s",INDEPENDENT=YES
                """
            ),
            for: sourceURL
        )

        let snapshot = try await HLSLivePlaylistClient(
            session: fixture.session
        ).snapshot(from: sourceURL)

        #expect(snapshot.initializationSegments.isEmpty)
    }

    @Test("confirmed MAP and PART preloads seed fragmented MP4 DVR")
    func reusesInitialMapAndPartPreloads() async throws {
        let sourceURL = try url("https://media.example/preload-map.m3u8")
        let secondReloadURL = try url(
            "https://media.example/preload-map.m3u8?_HLS_msn=11&_HLS_part=1"
        )
        let mapURL = try url("https://media.example/init.mp4")
        let firstPartURL = try url("https://media.example/11.0.m4s")
        let secondPartURL = try url("https://media.example/11.1.m4s")
        let parentURL = try url("https://media.example/11.m4s")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-PRELOAD-HINT:TYPE=MAP,URI="init.mp4"
                #EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.0.m4s"
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-MAP:URI="init.mp4"
                #EXT-X-PART:DURATION=1,URI="11.0.m4s",INDEPENDENT=YES
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:11
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
                #EXT-X-PART-INF:PART-TARGET=1
                #EXT-X-MAP:URI="init.mp4"
                #EXT-X-PART:DURATION=1,URI="11.0.m4s",INDEPENDENT=YES
                #EXT-X-PART:DURATION=1,URI="11.1.m4s"
                #EXTINF:2,
                11.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: secondReloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("init".utf8)),
            for: mapURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent),
            preloading: HLSLiveDVRPreloadPack(
                policy: .unencryptedMedia
            )
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 2)
        let requests = HLSLiveURLProtocol.capturedRequests()
        #expect(requests.filter { $0.url == mapURL }.count == 1)
        #expect(requests.filter { $0.url == firstPartURL }.count == 1)
        #expect(!requests.compactMap(\.url).contains(parentURL))
        #expect(
            try Data(
                contentsOf: fixture.destinationURL
                    .appendingPathComponent("resources/initialization.mp4")
            ) == Data("init".utf8)
        )
        let partStatistics =
            receipt.preloadStatistics.partialSegments
        #expect(partStatistics.requestCount == 1)
        #expect(partStatistics.completedCount == 1)
        #expect(partStatistics.confirmedCount == 1)
        #expect(partStatistics.reuseCount == 1)
        #expect(partStatistics.missCount == 1)
        #expect(partStatistics.transferredByteCount == 3)
        #expect(partStatistics.reusedByteCount == 3)
        let mapStatistics =
            receipt.preloadStatistics.initializationMaps
        #expect(mapStatistics.requestCount == 1)
        #expect(mapStatistics.completedCount == 1)
        #expect(mapStatistics.confirmedCount == 1)
        #expect(mapStatistics.reuseCount == 1)
        #expect(mapStatistics.missCount == 0)
        #expect(mapStatistics.transferredByteCount == 4)
        #expect(mapStatistics.reusedByteCount == 4)
    }

    @Test("LL-HLS part capture remains opt-in")
    func leavesPartCaptureDisabledByDefault() async throws {
        let sourceURL = try url("https://media.example/default-parts.m3u8")
        let reloadURL = try url(
            "https://media.example/default-parts.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let preloadPartURL = try url("https://media.example/11.2.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                partialPlaylist()
                    + "\n#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"11.2.ts\""
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(completedPartialPlaylist()),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("parent".utf8)),
            for: parentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 0)
        #expect(
            receipt.preloadStatistics
                == HLSLiveDVRPreloadStatistics()
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(!requests.contains(firstPartURL))
        #expect(!requests.contains(secondPartURL))
        #expect(!requests.contains(preloadPartURL))
        #expect(requests.contains(parentURL))
    }

    @Test("a mismatched part set falls back to its complete parent")
    func fallsBackFromMismatchedParts() async throws {
        let sourceURL = try url("https://media.example/mismatch.m3u8")
        let reloadURL = try url(
            "https://media.example/mismatch.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                partialPlaylist(firstDuration: 2, secondDuration: 1.8)
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(completedPlaylistWithoutParts()),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("one".utf8)),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("two".utf8)),
            for: secondPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("parent".utf8)),
            for: parentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 0)
        #expect(receipt.mediaByteCount == 6)
        #expect(
            try Data(
                contentsOf: fixture.destinationURL
                    .appendingPathComponent("resources/00000.ts")
            ) == Data("parent".utf8)
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(requests.contains(firstPartURL))
        #expect(requests.contains(secondPartURL))
        #expect(requests.contains(parentURL))
    }

    @Test("a failed part is not retried for the same parent sequence")
    func abandonsFailedPartSequence() async throws {
        let sourceURL = try url("https://media.example/failed-part.m3u8")
        let reloadURL = try url(
            "https://media.example/failed-part.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(partialPlaylist()),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(partialPlaylist()),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(completedPlaylistWithoutParts()),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            HLSLiveURLProtocol.Response(
                statusCode: 404,
                data: Data(),
                headers: [:]
            ),
            for: firstPartURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("parent".utf8)),
            for: parentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 0)
        #expect(
            HLSLiveURLProtocol.capturedRequests().filter {
                $0.url == firstPartURL
            }.count == 1
        )
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url).contains(parentURL)
        )
    }

    @Test("part staging never starts from a dependent first part")
    func rejectsDependentFirstPart() async throws {
        let sourceURL = try url("https://media.example/dependent.m3u8")
        let reloadURL = try url(
            "https://media.example/dependent.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let parentURL = try url("https://media.example/11.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(partialPlaylist(firstIsIndependent: false)),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                completedPartialPlaylist(firstIsIndependent: false)
            ),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("parent".utf8)),
            for: parentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 0)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(!requests.contains(firstPartURL))
        #expect(!requests.contains(secondPartURL))
        #expect(requests.contains(parentURL))
    }

    @Test("AES-128 LL-HLS waits for and decrypts the complete parent")
    func skipsEncryptedParts() async throws {
        let sourceURL = try url("https://media.example/encrypted-parts.m3u8")
        let reloadURL = try url(
            "https://media.example/encrypted-parts.m3u8?_HLS_msn=11&_HLS_part=2"
        )
        let firstPartURL = try url("https://media.example/11.0.ts")
        let secondPartURL = try url("https://media.example/11.1.ts")
        let keyURL = try url("https://media.example/live.key")
        let parentURL = try url("https://media.example/11.ts")
        let key = Data(repeating: 0x31, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([11])
        let plaintext = Data("parent".utf8)
        let ciphertext = try aes128Encrypt(
            plaintext,
            key: key,
            initializationVector: initializationVector
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(encryptedPartialPlaylist(isEnded: false)),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(encryptedPartialPlaylist(isEnded: true)),
            for: reloadURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(ciphertext),
            for: parentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment,
            parts: HLSLiveDVRPartPack(policy: .independent)
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 0)
        #expect(
            try Data(
                contentsOf: fixture.destinationURL
                    .appendingPathComponent("resources/00000.ts")
            ) == plaintext
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(!requests.contains(firstPartURL))
        #expect(!requests.contains(secondPartURL))
        #expect(requests.contains(keyURL))
        #expect(requests.contains(parentURL))
    }

    @Test("an existing destination fails before the playlist request")
    func existingDestinationIsRejected() async throws {
        let sourceURL = try url(
            "https://media.example/existing-destination.m3u8"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        try FileManager.default.createDirectory(
            at: fixture.destinationURL,
            withIntermediateDirectories: false
        )

        await #expect(
            throws: HLSLiveDVRError.destinationAlreadyExists
        ) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(HLSLiveURLProtocol.capturedRequests().isEmpty)
    }

    @Test("a lost live window leaves no partial package")
    func liveWindowAdvanceIsRejectedAtomically() async throws {
        let sourceURL = try url(
            "https://media.example/window-advance.m3u8"
        )
        let reloadURL = try url(
            "https://media.example/window-advance.m3u8?_HLS_msn=2"
        )
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:1
                #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
                #EXTINF:4,
                1.ts
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-MEDIA-SEQUENCE:3
                #EXTINF:4,
                3.ts
                #EXT-X-ENDLIST
                """
            ),
            for: reloadURL
        )

        await #expect(throws: HLSLiveDVRError.liveWindowAdvanced) {
            try await recorder(
                session: fixture.session,
                startPosition: .nextCompletedSegment
            ).record(
                from: sourceURL,
                to: fixture.destinationURL
            )
        }
        #expect(
            HLSLiveURLProtocol.capturedRequests()
                .compactMap(\.url) == [sourceURL, reloadURL]
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
    }

    private func assertAES128Failure(
        keyResponse: HLSLiveURLProtocol.Response,
        mediaData: Data = Data(repeating: 0, count: 16),
        expectedError: HLSLiveDVRError
    ) async throws {
        let sourceURL = try url("https://media.example/failure.m3u8")
        let keyURL = try url("https://media.example/failure.key")
        let segmentURL = try url("https://media.example/failure.ts")
        let fixture = try makeFixture()
        defer {
            fixture.cleanup()
            HLSLiveURLProtocol.reset()
        }
        HLSLiveURLProtocol.register(
            playlistResponse(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:4
                #EXT-X-KEY:METHOD=AES-128,URI="failure.key",IV=0x00000000000000000000000000000001
                #EXTINF:4,
                failure.ts
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(keyResponse, for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(mediaData),
            for: segmentURL
        )

        await #expect(throws: expectedError) {
            try await recorder(
                session: fixture.session,
                startPosition: .currentWindow
            ).record(from: sourceURL, to: fixture.destinationURL)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.destinationURL.path
            )
        )
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        switch expectedError {
        case .decryptionFailed:
            #expect(requests == [sourceURL, keyURL, segmentURL])
        default:
            #expect(requests == [sourceURL, keyURL])
        }
    }

    private func packageFileNames(
        _ directoryURL: URL
    ) throws -> [String] {
        try packageFileURLs(directoryURL).map(\.lastPathComponent)
    }

    private func packageFileData(
        _ directoryURL: URL
    ) throws -> [Data] {
        try packageFileURLs(directoryURL).map {
            try Data(contentsOf: $0)
        }
    }

    private func packageFileURLs(
        _ directoryURL: URL
    ) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        return try enumerator.compactMap {
            guard let url = $0 as? URL else {
                return nil
            }
            return try url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile == true ? url : nil
        }
    }

    private func recorder(
        session: URLSession,
        startPosition: HLSLiveDVRStartPosition,
        renditions: HLSLiveDVRRenditionPack =
            HLSLiveDVRRenditionPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack(),
        preloading: HLSLiveDVRPreloadPack = HLSLiveDVRPreloadPack(),
        recovery: HLSLiveDVRRecoveryPack = HLSLiveDVRRecoveryPack(),
        requestPolicy: HLSRequestPolicy = HLSRequestPolicy()
    ) -> HLSLiveDVRRecorder {
        HLSLiveDVRRecorder(
            client: HLSLivePlaylistClient(
                session: session,
                requestPolicy: requestPolicy
            ),
            configuration: .advanced(
                limits: HLSLiveDVRLimitPack(
                    maximumDuration: 60,
                    maximumSegmentCount: 20,
                    maximumMediaResourceBytes: 1_024,
                    maximumTotalMediaBytes: 4_096
                ),
                startPosition: startPosition,
                renditions: renditions,
                parts: parts,
                preloading: preloading,
                recovery: recovery
            )
        )
    }

    private func rollingRecorder(
        session: URLSession,
        maximumDuration: TimeInterval = 60,
        maximumSegmentCount: Int,
        maximumTotalMediaBytes: Int64 = 4_096,
        recovery: HLSLiveDVRRecoveryPack = HLSLiveDVRRecoveryPack(),
        parts: HLSLiveDVRPartPack = HLSLiveDVRPartPack()
    ) -> HLSLiveDVRRecorder {
        HLSLiveDVRRecorder(
            client: HLSLivePlaylistClient(session: session),
            configuration: .advanced(
                limits: HLSLiveDVRLimitPack(
                    maximumDuration: maximumDuration,
                    maximumSegmentCount: maximumSegmentCount,
                    maximumMediaResourceBytes: 1_024,
                    maximumTotalMediaBytes: maximumTotalMediaBytes,
                    retentionPolicy: .rollingWindow
                ),
                startPosition: .currentWindow,
                parts: parts,
                recovery: recovery
            )
        )
    }

    private func recoveryRecorder(
        session: URLSession
    ) -> HLSLiveDVRRecorder {
        recorder(
            session: session,
            startPosition: .currentWindow,
            recovery: HLSLiveDVRRecoveryPack(policy: .resumable)
        )
    }

    private func interruptedRecoveryRecorder(
        sourceURL: URL,
        segmentURL: URL,
        fixture: DVRFixture
    ) async throws -> HLSLiveDVRRecorder {
        HLSLiveURLProtocol.register(
            playlistResponse(
                uninterruptedRecoveryPlaylist(
                    segmentName: segmentURL.lastPathComponent
                )
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(Data("first".utf8)),
            for: segmentURL
        )
        let recorder = recoveryRecorder(session: fixture.session)
        let recording = recorder.startRecording(
            from: sourceURL,
            to: fixture.destinationURL
        )
        var events = recording.events.makeAsyncIterator()
        guard case .progress(let progress) = try await events.next() else {
            throw HLSLiveDVRError.recoveryUnavailable
        }
        guard progress.segmentCount == 1 else {
            throw HLSLiveDVRError.recoveryCorrupted
        }
        await recording.interrupt()
        return recorder
    }

    private func uninterruptedRecoveryPlaylist(
        segmentName: String
    ) -> String {
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:60
        #EXT-X-MEDIA-SEQUENCE:10
        #EXTINF:4,
        \(segmentName)
        """
    }

    private func partialPlaylist(
        firstDuration: TimeInterval = 2,
        secondDuration: TimeInterval = 2,
        firstIsIndependent: Bool = true
    ) -> String {
        let independent = firstIsIndependent ? ",INDEPENDENT=YES" : ""
        return """
            #EXTM3U
            #EXT-X-VERSION:9
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:10
            #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=4
            #EXT-X-PART-INF:PART-TARGET=2
            #EXTINF:4,
            10.ts
            #EXT-X-PART:DURATION=\(firstDuration),URI="11.0.ts"\(independent)
            #EXT-X-PART:DURATION=\(secondDuration),URI="11.1.ts"
            """
    }

    private func completedPartialPlaylist(
        firstDuration: TimeInterval = 2,
        secondDuration: TimeInterval = 2,
        firstIsIndependent: Bool = true
    ) -> String {
        partialPlaylist(
            firstDuration: firstDuration,
            secondDuration: secondDuration,
            firstIsIndependent: firstIsIndependent
        ) + """

                #EXTINF:4,
                11.ts
            #EXT-X-ENDLIST
            """
    }

    private func completedPlaylistWithoutParts() -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:9
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:10
        #EXTINF:4,
        10.ts
        #EXTINF:4,
        11.ts
        #EXT-X-ENDLIST
        """
    }

    private func encryptedPartialPlaylist(
        isEnded: Bool
    ) -> String {
        partialPlaylist()
            .replacingOccurrences(
                of: "#EXTINF:4,\n10.ts",
                with:
                    "#EXT-X-KEY:METHOD=AES-128,URI=\"live.key\",IV=0x0000000000000000000000000000000B\n#EXTINF:4,\n10.ts"
            )
            + (isEnded
                ? """

                #EXTINF:4,
                11.ts
                #EXT-X-ENDLIST
                """
                : "")
    }

    private func makeFixture() throws -> DVRFixture {
        let rootURL =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetwork-HLSLiveDVR-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSLiveURLProtocol.self]
        return DVRFixture(
            rootURL: rootURL,
            destinationURL:
                rootURL.appendingPathComponent(
                    "recording",
                    isDirectory: true
                ),
            session: URLSession(configuration: configuration)
        )
    }

    private func playlistResponse(
        _ playlist: String,
        delay: TimeInterval = 0
    ) -> HLSLiveURLProtocol.Response {
        HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: Data(playlist.utf8),
            headers: [
                "Content-Type":
                    "application/vnd.apple.mpegurl"
            ],
            delay: delay
        )
    }

    private func mediaResponse(
        _ data: Data,
        delay: TimeInterval = 0
    ) -> HLSLiveURLProtocol.Response {
        HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: data,
            headers: [
                "Content-Length": "\(data.count)",
                "Content-Type": "application/octet-stream",
            ],
            delay: delay
        )
    }

    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }
}

private struct DVRFixture {
    let rootURL: URL
    let destinationURL: URL
    let session: URLSession

    func cleanup() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor HLSLiveDVRRequestRecorder: HLSRequestEventObserving {
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

private func sequenceIV(_ sequenceNumber: Int64) -> Data {
    var value = UInt64(sequenceNumber).bigEndian
    var initializationVector = Data(repeating: 0, count: 8)
    withUnsafeBytes(of: &value) {
        initializationVector.append(contentsOf: $0)
    }
    return initializationVector
}

private func aes128Encrypt(
    _ plaintext: Data,
    key: Data,
    initializationVector: Data
) throws -> Data {
    var ciphertext = Data(
        count: plaintext.count + kCCBlockSizeAES128
    )
    let outputCapacity = ciphertext.count
    var outputLength = 0
    let status = ciphertext.withUnsafeMutableBytes { outputBytes in
        plaintext.withUnsafeBytes { plaintextBytes in
            key.withUnsafeBytes { keyBytes in
                initializationVector.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        plaintextBytes.baseAddress,
                        plaintext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else {
        throw HLSLiveDVRError.decryptionFailed
    }
    ciphertext.count = outputLength
    return ciphertext
}
