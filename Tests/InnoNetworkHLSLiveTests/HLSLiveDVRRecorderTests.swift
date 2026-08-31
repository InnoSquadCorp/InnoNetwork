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

        let parts = HLSLiveDVRPartPack(
            policy: .independent,
            maximumStagedPartCount: -1,
            maximumStagedPartBytes: -1
        )
        #expect(parts.policy == .independent)
        #expect(parts.maximumStagedPartCount == 1)
        #expect(parts.maximumStagedPartBytes == 1)
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
        #expect(receipt.firstMediaSequence == 10)
        #expect(receipt.lastMediaSequence == 11)
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
    func renditionCheckpointStoragePathIsDistinct() {
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
            checkpoint.file.relativePath
                == "audio/00/resources/00000.aac"
        )
        #expect(
            checkpoint.storedSegment.fileName
                == "resources/00000.aac"
        )
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

    @Test("resuming retains external rendition files without collisions")
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
            "https://media.example/audio-10.aac?token=old"
        )
        let newVideoURL = try url(
            "https://media.example/video-11.ts?token=new"
        )
        let newAudioURL = try url(
            "https://media.example/audio-11.aac?token=new"
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
        HLSLiveURLProtocol.register(
            playlistResponse(master("old")),
            for: masterURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(firstPlaylist("video-10.ts?token=old")),
            for: oldVideoPlaylistURL
        )
        HLSLiveURLProtocol.register(
            playlistResponse(firstPlaylist("audio-10.aac?token=old")),
            for: oldAudioPlaylistURL
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
            playlistResponse(
                resumedPlaylist(
                    "audio-10.aac?token=new",
                    "audio-11.aac?token=new"
                )
            ),
            for: newAudioPlaylistURL
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

    @Test("encrypted fragmented MP4 decrypts its map and media")
    func recordsEncryptedFragmentedMP4() async throws {
        let sourceURL = try url("https://media.example/encrypted-fmp4.m3u8")
        let keyURL = try url("https://media.example/fmp4.key")
        let initializationURL = try url("https://media.example/init.mp4")
        let segmentURL = try url("https://media.example/1.m4s")
        let key = Data(repeating: 0x31, count: 16)
        let initializationVector =
            Data(repeating: 0, count: 15) + Data([3])
        let initializationPlaintext = Data("encrypted init".utf8)
        let mediaPlaintext = Data("encrypted fragment".utf8)
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
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:4,
                1.m4s
                #EXT-X-ENDLIST
                """
            ),
            for: sourceURL
        )
        HLSLiveURLProtocol.register(mediaResponse(key), for: keyURL)
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    initializationPlaintext,
                    key: key,
                    initializationVector: initializationVector
                )
            ),
            for: initializationURL
        )
        HLSLiveURLProtocol.register(
            mediaResponse(
                try aes128Encrypt(
                    mediaPlaintext,
                    key: key,
                    initializationVector: initializationVector
                )
            ),
            for: segmentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .currentWindow
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(
            try Data(
                contentsOf: receipt.directoryURL.appendingPathComponent(
                    "resources/initialization.mp4"
                )
            ) == initializationPlaintext
        )
        #expect(
            try Data(
                contentsOf: receipt.directoryURL
                    .appendingPathComponent("resources/00000.m4s")
            ) == mediaPlaintext
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

    @Test("LL-HLS part capture remains opt-in")
    func leavesPartCaptureDisabledByDefault() async throws {
        let sourceURL = try url("https://media.example/default-parts.m3u8")
        let reloadURL = try url(
            "https://media.example/default-parts.m3u8?_HLS_msn=11&_HLS_part=2"
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
            mediaResponse(Data("parent".utf8)),
            for: parentURL
        )

        let receipt = try await recorder(
            session: fixture.session,
            startPosition: .nextCompletedSegment
        ).record(from: sourceURL, to: fixture.destinationURL)

        #expect(receipt.promotedPartCount == 0)
        let requests = HLSLiveURLProtocol.capturedRequests().compactMap(\.url)
        #expect(!requests.contains(firstPartURL))
        #expect(!requests.contains(secondPartURL))
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
        recovery: HLSLiveDVRRecoveryPack = HLSLiveDVRRecoveryPack()
    ) -> HLSLiveDVRRecorder {
        HLSLiveDVRRecorder(
            client: HLSLivePlaylistClient(session: session),
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
        _ playlist: String
    ) -> HLSLiveURLProtocol.Response {
        HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: Data(playlist.utf8),
            headers: [
                "Content-Type":
                    "application/vnd.apple.mpegurl"
            ]
        )
    }

    private func mediaResponse(
        _ data: Data
    ) -> HLSLiveURLProtocol.Response {
        HLSLiveURLProtocol.Response(
            statusCode: 200,
            data: data,
            headers: [
                "Content-Length": "\(data.count)",
                "Content-Type": "application/octet-stream",
            ]
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
