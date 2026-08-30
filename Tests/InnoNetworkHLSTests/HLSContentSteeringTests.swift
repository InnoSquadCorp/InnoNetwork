import Foundation
import InnoNetwork
import Testing
import os

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("pathway health penalizes and recovers on session time")
    func contentSteeringPathwayHealthRecoversAfterCooldown() async {
        let observationTime = OSAllocatedUnfairLock<Date>(
            initialState: Date(timeIntervalSince1970: 1_000)
        )
        let recorder = HLSContentSteeringEventRecorder()
        let settings = HLSContentSteeringPack(
            healthPolicy: HLSContentSteeringHealthPolicy(
                consecutiveFailureThreshold: 2,
                recoveryCooldown: .seconds(10)
            ),
            eventObservers: [recorder]
        ).resolvedSettings
        let session = HLSContentSteeringSession(
            settings: settings,
            now: { observationTime.withLock { $0 } }
        )

        #expect(
            await session.beginAttempt(
                pathwayID: "A",
                phase: .mediaPlaylist,
                resourceIndex: nil
            ) == .admitted
        )
        await session.recordFailure(
            pathwayID: "A",
            phase: .mediaPlaylist,
            resourceIndex: nil,
            errorCode: .transferFailed
        )
        #expect(
            await session.beginAttempt(
                pathwayID: "A",
                phase: .mediaPlaylist,
                resourceIndex: nil
            ) == .admitted
        )
        await session.recordFailure(
            pathwayID: "A",
            phase: .mediaPlaylist,
            resourceIndex: nil,
            errorCode: .invalidResponseStatus
        )
        #expect(
            await session.beginAttempt(
                pathwayID: "A",
                phase: .mediaPlaylist,
                resourceIndex: nil
            ) == .penalized
        )

        observationTime.withLock {
            $0.addTimeInterval(10)
        }
        #expect(
            await session.beginAttempt(
                pathwayID: "A",
                phase: .mediaPlaylist,
                resourceIndex: nil
            ) == .recovered
        )
        await session.recordSuccess(
            pathwayID: "A",
            phase: .mediaPlaylist,
            resourceIndex: nil,
            selection: HLSContentSteeringSession.Selection(
                fromPathwayID: "B",
                reason: .cooldownRecovery
            )
        )

        let events = await recorder.events()
        let health: [HLSContentSteeringPathwaySnapshot] =
            events.compactMap { event in
                guard case .pathwayHealthChanged(let snapshot) = event else {
                    return nil
                }
                return snapshot
            }
        let penalized = health.first { snapshot in
            guard case .penalized = snapshot.availability else {
                return false
            }
            return true
        }
        #expect(penalized?.attemptCount == 2)
        #expect(penalized?.failureCount == 2)
        #expect(penalized?.consecutiveFailureCount == 2)
        #expect(
            penalized?.availability
                == .penalized(retryAfter: .seconds(10))
        )
        let final = health.last
        #expect(final?.attemptCount == 3)
        #expect(final?.successCount == 1)
        #expect(final?.failureCount == 2)
        #expect(final?.successRate == 1.0 / 3.0)
        #expect(final?.consecutiveFailureCount == 0)
        #expect(final?.availability == .available)
        #expect(final?.selectionCounts[.cooldownRecovery] == 1)
        #expect(
            events.contains(
                .pathwaySelectionChanged(
                    fromPathwayID: "B",
                    toPathwayID: "A",
                    reason: .cooldownRecovery
                )
            )
        )
        let diagnostic = String(reflecting: events)
        #expect(!diagnostic.contains("https://"))
        #expect(!diagnostic.contains("token="))
    }

    @Test("pathway health policy remains bounded")
    func contentSteeringPathwayHealthPolicyIsBounded() {
        let minimum = HLSContentSteeringHealthPolicy(
            consecutiveFailureThreshold: .min,
            recoveryCooldown: .seconds(-1)
        )
        #expect(minimum.consecutiveFailureThreshold == 1)
        #expect(minimum.recoveryCooldown == .zero)

        let maximum = HLSContentSteeringHealthPolicy(
            consecutiveFailureThreshold: .max,
            recoveryCooldown: .seconds(86_400)
        )
        #expect(maximum.consecutiveFailureThreshold == 16)
        #expect(maximum.recoveryCooldown == .seconds(3_600))
    }

    @Test("VOD pathway can re-enter after its cooldown")
    func vodPathwayReentersAfterCooldown() async throws {
        let urls = try makeContentSteeringURLs()
        let cloneFirstURL = try #require(
            URL(string: "https://edge.example/one.ts")
        )
        let cloneSecondURL = try #require(
            URL(string: "https://edge.example/two.ts")
        )
        let baseFirstURL = try #require(
            URL(string: "https://media.example/one.ts")
        )
        let baseSecondURL = try #require(
            URL(string: "https://media.example/two.ts")
        )
        let clock = HLSContentSteeringTestClock()
        let recorder = HLSContentSteeringEventRecorder()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        let mediaPlaylist = Data(
            """
            #EXTM3U
            #EXTINF:1,
            one.ts
            #EXTINF:1,
            two.ts
            #EXT-X-ENDLIST

            """.utf8
        )
        for url in [urls.cloneMedia, urls.baseMedia] {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: mediaPlaylist,
                    headers: [:]
                ),
                for: url
            )
        }
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: cloneFirstURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("1".utf8),
                headers: ["Content-Length": "1"]
            ),
            for: baseFirstURL
        )
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: baseSecondURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("2".utf8),
                headers: ["Content-Length": "1"]
            ),
            for: cloneSecondURL
        )
        HLSURLProtocol.setStartLoadingHandler { url in
            if url == baseSecondURL {
                clock.advance(by: 2)
            }
        }
        let client = HLSHTTPClient(
            session: session,
            requestContext: NetworkRequestContext(),
            requestAdapter: { $0 }
        )
        let downloader = HLSDownloader(
            client: client,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .disabled,
                    resumePolicy: .disabled
                ),
                contentSteering: HLSContentSteeringPack(
                    healthPolicy: HLSContentSteeringHealthPolicy(
                        recoveryCooldown: .seconds(1)
                    ),
                    eventObservers: [recorder]
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            ),
            clock: clock
        )
        let directoryURL = try makeContentSteeringTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "cooldown.ts"
        )

        _ = try await downloader.downloadReceipt(
            sourceURL: urls.master,
            destinationURL: destinationURL
        )

        #expect(try Data(contentsOf: destinationURL) == Data("12".utf8))
        #expect(
            await recorder.events().contains(
                .pathwaySelectionChanged(
                    fromPathwayID: "A",
                    toPathwayID: "B",
                    reason: .cooldownRecovery
                )
            )
        )
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [
                    urls.master,
                    urls.steering,
                    urls.cloneMedia,
                    cloneFirstURL,
                    urls.baseMedia,
                    baseFirstURL,
                    baseSecondURL,
                    urls.cloneMedia,
                    cloneSecondURL,
                ]
        )
    }

    @Test("statistics-only health does not cycle failed pathways")
    func zeroCooldownDoesNotCycleFailedPathways() async throws {
        let urls = try makeContentSteeringURLs()
        let cloneSegmentURL = try #require(
            URL(string: "https://edge.example/segment.ts")
        )
        let baseSegmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        registerContentSteeringMediaPlaylist(at: urls.cloneMedia)
        registerContentSteeringMediaPlaylist(at: urls.baseMedia)
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: cloneSegmentURL
        )
        HLSURLProtocol.register(
            .success(statusCode: 502, data: Data(), headers: [:]),
            for: baseSegmentURL
        )
        let directoryURL = try makeContentSteeringTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        await #expect(
            throws: HLSDownloadError.invalidMediaResponseStatus(502)
        ) {
            try await HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled,
                        resumePolicy: .disabled
                    ),
                    contentSteering: HLSContentSteeringPack(
                        healthPolicy: HLSContentSteeringHealthPolicy(
                            recoveryCooldown: .zero
                        )
                    ),
                    transfer: HLSTransferPack(
                        maximumConcurrentResourceTransfers: 1,
                        retryPolicy: nil
                    )
                )
            ).downloadReceipt(
                sourceURL: urls.master,
                destinationURL:
                    directoryURL.appendingPathComponent("failed.ts")
            )
        }
        #expect(
            HLSURLProtocol.capturedRequests().count {
                $0.url == cloneSegmentURL
            } == 1
        )
        #expect(
            HLSURLProtocol.capturedRequests().count {
                $0.url == baseSegmentURL
            } == 1
        )
    }

    @Test("playlist declarations expose resolved steering metadata")
    func parsesContentSteeringDeclaration() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/path/master.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-CONTENT-STEERING:SERVER-URI="../steering.json",PATHWAY-ID="A"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,PATHWAY-ID="A"
            a.m3u8

            """,
            relativeTo: sourceURL
        )

        #expect(
            playlist.contentSteering?.serverURL.absoluteString
                == "https://media.example/steering.json"
        )
        #expect(playlist.contentSteering?.initialPathwayID == "A")

        let invalid = [
            """
            #EXTM3U
            #EXT-X-CONTENT-STEERING:SERVER-URI=https://steering.example/manifest.json
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            a.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-CONTENT-STEERING:SERVER-URI="https://steering.example/one.json"
            #EXT-X-CONTENT-STEERING:SERVER-URI="https://steering.example/two.json"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            a.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-CONTENT-STEERING:SERVER-URI="https://steering.example/manifest.json",PATHWAY-ID="missing"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,PATHWAY-ID="A"
            a.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-CONTENT-STEERING:SERVER-URI="https://steering.example/manifest.json"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
        ]
        for contents in invalid {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    contents,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("manifest priority selects a cloned pathway")
    func selectsClonedPathway() async throws {
        let urls = try makeContentSteeringURLs()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        registerContentSteeringMediaPlaylist(at: urls.cloneMedia)

        let preparation = try await HLSDownloader(
            session: session
        ).prepare(sourceURL: urls.master)

        #expect(preparation.selectedVariant?.pathwayID == "B")
        #expect(preparation.selectedVariant?.hdcpLevel == .type1)
        #expect(
            preparation.selectedVariant?.requiredVideoLayouts.first?
                .projection == .halfEquirectangular
        )
        #expect(preparation.mediaPlaylistURL == urls.cloneMedia)
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [urls.master, urls.steering, urls.cloneMedia]
        )
    }

    @Test("playlist resolution falls through to the next pathway")
    func failsOverToNextPathway() async throws {
        let urls = try makeContentSteeringURLs()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: urls.cloneMedia
        )
        registerContentSteeringMediaPlaylist(at: urls.baseMedia)

        let preparation = try await HLSDownloader(
            session: session
        ).prepare(sourceURL: urls.master)

        #expect(preparation.selectedVariant?.pathwayID == "A")
        #expect(preparation.mediaPlaylistURL == urls.baseMedia)
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [
                    urls.master,
                    urls.steering,
                    urls.cloneMedia,
                    urls.baseMedia,
                ]
        )
    }

    @Test("media transfer failure switches to a compatible pathway")
    func mediaTransferFailureSwitchesPathway() async throws {
        let urls = try makeContentSteeringURLs()
        let cloneSegmentURL = try #require(
            URL(string: "https://edge.example/segment.ts")
        )
        let baseSegmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        registerContentSteeringMediaPlaylist(at: urls.cloneMedia)
        registerContentSteeringMediaPlaylist(at: urls.baseMedia)
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: cloneSegmentURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("fallback".utf8),
                headers: ["Content-Length": "8"]
            ),
            for: baseSegmentURL
        )
        let recorder = HLSContentSteeringEventRecorder()
        let directoryURL = try makeContentSteeringTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "fallback.ts"
        )

        let receipt = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .disabled,
                    resumePolicy: .disabled
                ),
                contentSteering: HLSContentSteeringPack(
                    eventObservers: [recorder]
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 1,
                    retryPolicy: nil
                )
            )
        ).downloadReceipt(
            sourceURL: urls.master,
            destinationURL: destinationURL
        )

        #expect(receipt.selectedVariant?.pathwayID == "B")
        #expect(
            try Data(contentsOf: destinationURL)
                == Data("fallback".utf8)
        )
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [
                    urls.master,
                    urls.steering,
                    urls.cloneMedia,
                    cloneSegmentURL,
                    urls.baseMedia,
                    baseSegmentURL,
                ]
        )
        let events = await recorder.events()
        #expect(
            events.contains(
                .pathwayFailed(
                    pathwayID: "B",
                    phase: .mediaResource,
                    resourceIndex: 0,
                    errorCode: .invalidMediaResponseStatus
                )
            )
        )
        #expect(
            events.contains(
                .pathwaySelected(
                    pathwayID: "A",
                    phase: .mediaResource,
                    resourceIndex: 0
                )
            )
        )
        let diagnostic = String(reflecting: events)
        #expect(!diagnostic.contains("https://"))
        #expect(!diagnostic.contains("token=clone"))
    }

    @Test("concurrent failures share one pathway activation")
    func concurrentFailuresSharePathwayActivation() async throws {
        let urls = try makeContentSteeringURLs()
        let cloneSegmentURLs = try [
            #require(URL(string: "https://edge.example/one.ts")),
            #require(URL(string: "https://edge.example/two.ts")),
        ]
        let baseSegmentURLs = try [
            #require(URL(string: "https://media.example/one.ts")),
            #require(URL(string: "https://media.example/two.ts")),
        ]
        let mediaPlaylist = Data(
            """
            #EXTM3U
            #EXTINF:1,
            one.ts
            #EXTINF:1,
            two.ts
            #EXT-X-ENDLIST

            """.utf8
        )
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: mediaPlaylist,
                headers: [:]
            ),
            for: urls.cloneMedia
        )
        HLSURLProtocol.register(
            .delayedSuccess(
                statusCode: 200,
                data: mediaPlaylist,
                headers: [:],
                delay: 0.03
            ),
            for: urls.baseMedia
        )
        for url in cloneSegmentURLs {
            HLSURLProtocol.register(
                .success(
                    statusCode: 503,
                    data: Data(),
                    headers: [:]
                ),
                for: url
            )
        }
        for (url, value) in zip(
            baseSegmentURLs,
            ["A", "B"]
        ) {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: Data(value.utf8),
                    headers: ["Content-Length": "1"]
                ),
                for: url
            )
        }
        let directoryURL = try makeContentSteeringTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "concurrent.ts"
        )

        _ = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .disabled,
                    resumePolicy: .disabled
                ),
                transfer: HLSTransferPack(
                    maximumConcurrentResourceTransfers: 2,
                    retryPolicy: nil
                )
            )
        ).downloadReceipt(
            sourceURL: urls.master,
            destinationURL: destinationURL
        )

        #expect(try Data(contentsOf: destinationURL) == Data("AB".utf8))
        #expect(
            HLSURLProtocol.capturedRequests().count {
                $0.url == urls.baseMedia
            } == 1
        )
        for url in baseSegmentURLs {
            #expect(
                HLSURLProtocol.capturedRequests().count {
                    $0.url == url
                } == 1
            )
        }
    }

    @Test("transfer failover rejects a changed resource plan")
    func transferFailoverRejectsChangedPlan() async throws {
        let urls = try makeContentSteeringURLs()
        let cloneSegmentURL = try #require(
            URL(string: "https://edge.example/segment.ts")
        )
        let changedSegmentURL = try #require(
            URL(string: "https://media.example/different.ts")
        )
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        registerContentSteeringMediaPlaylist(at: urls.cloneMedia)
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    different.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: urls.baseMedia
        )
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: cloneSegmentURL
        )
        let directoryURL = try makeContentSteeringTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        await #expect(
            throws: HLSDownloadError.invalidMediaResponseStatus(503)
        ) {
            try await HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled,
                        resumePolicy: .disabled
                    ),
                    transfer: HLSTransferPack(
                        maximumConcurrentResourceTransfers: 1,
                        retryPolicy: nil
                    )
                )
            ).downloadReceipt(
                sourceURL: urls.master,
                destinationURL:
                    directoryURL.appendingPathComponent("rejected.ts")
            )
        }
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == changedSegmentURL
            }
        )
    }

    @Test("steering manifests are cached for their TTL")
    func cachesManifestUntilTTLExpires() async throws {
        let urls = try makeContentSteeringURLs()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        registerContentSteeringMediaPlaylist(at: urls.cloneMedia)
        let downloader = HLSDownloader(session: session)

        _ = try await downloader.prepare(sourceURL: urls.master)
        _ = try await downloader.prepare(sourceURL: urls.master)

        let manifestRequestCount = HLSURLProtocol.capturedRequests().count {
            $0.url == urls.steering
        }
        #expect(manifestRequestCount == 1)
    }

    @Test("disabled steering uses the declared initial pathway")
    func disabledSteeringUsesInitialPathway() async throws {
        let urls = try makeContentSteeringURLs()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringMediaPlaylist(at: urls.baseMedia)

        let preparation = try await HLSDownloader(
            session: session,
            configuration: .advanced(contentSteering: .disabled)
        ).prepare(sourceURL: urls.master)

        #expect(preparation.selectedVariant?.pathwayID == "A")
        #expect(preparation.mediaPlaylistURL == urls.baseMedia)
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == urls.steering
            }
        )
    }

    @Test("unavailable manifests retain ordered pathway failover")
    func unavailableManifestFallsBackAcrossDeclaredPathways() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let steeringURL = try #require(
            URL(string: "https://steering.example/manifest.json")
        )
        let firstURL = try #require(
            URL(string: "https://a.example/media.m3u8")
        )
        let secondURL = try #require(
            URL(string: "https://b.example/media.m3u8")
        )
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-CONTENT-STEERING:SERVER-URI="\(steeringURL.absoluteString)",PATHWAY-ID="A"
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,PATHWAY-ID="A"
                    \(firstURL.absoluteString)
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,PATHWAY-ID="B"
                    \(secondURL.absoluteString)

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        HLSURLProtocol.register(
            .success(statusCode: 410, data: Data(), headers: [:]),
            for: steeringURL
        )
        HLSURLProtocol.register(
            .success(statusCode: 503, data: Data(), headers: [:]),
            for: firstURL
        )
        registerContentSteeringMediaPlaylist(at: secondURL)

        let preparation = try await HLSDownloader(
            session: session
        ).prepare(sourceURL: masterURL)

        #expect(preparation.selectedVariant?.pathwayID == "B")
        #expect(preparation.mediaPlaylistURL == secondURL)
    }

    @Test("data URL manifests steer without another network request")
    func resolvesDataURLManifest() async throws {
        let urls = try makeContentSteeringURLs()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        let manifest = contentSteeringManifestData()
        let dataURL = try #require(
            URL(
                string:
                    "data:application/json;base64,\(manifest.base64EncodedString())"
            )
        )
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: dataURL
        )
        registerContentSteeringMediaPlaylist(at: urls.cloneMedia)

        let preparation = try await HLSDownloader(
            session: session
        ).prepare(sourceURL: urls.master)

        #expect(preparation.selectedVariant?.pathwayID == "B")
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [urls.master, urls.cloneMedia]
        )
    }

    @Test("stable IDs can override cloned variant and rendition URLs")
    func appliesStableIDOverrides() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",STABLE-RENDITION-ID="audio-main",URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio",STABLE-VARIANT-ID="video-main",PATHWAY-ID="A"
            video.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,STABLE-VARIANT-ID="iframe-main",PATHWAY-ID="A",URI="iframe.m3u8"

            """,
            relativeTo: sourceURL
        )
        let manifest = try #require(
            HLSContentSteeringManifest.decode(
                Data(
                    """
                    {
                      "VERSION": 1,
                      "TTL": 30,
                      "PATHWAY-PRIORITY": ["B"],
                      "PATHWAY-CLONES": [{
                        "BASE-ID": "A",
                        "ID": "B",
                        "URI-REPLACEMENT": {
                          "PER-VARIANT-URIS": {
                            "video-main": "https://video.example/override.m3u8",
                            "iframe-main": "https://video.example/iframe-override.m3u8"
                          },
                          "PER-RENDITION-URIS": {"audio-main": "https://audio.example/override.m3u8"}
                        }
                      }]
                    }
                    """.utf8
                ),
                finalURL: sourceURL
            )
        )
        let catalog = try #require(
            HLSPathwayCatalogBuilder.make(
                playlist: playlist,
                manifest: manifest
            )
        )
        let pathway = try #require(catalog.pathways.first)

        #expect(pathway.id == "B")
        #expect(
            pathway.variants.first?.url.absoluteString
                == "https://video.example/override.m3u8"
        )
        #expect(pathway.variants.first?.audioGroupID == "audio@B")
        #expect(
            pathway.iFrameVariants.first?.url.absoluteString
                == "https://video.example/iframe-override.m3u8"
        )
        #expect(pathway.iFrameVariants.first?.pathwayID == "B")
        #expect(pathway.renditions.first?.groupID == "audio@B")
        #expect(
            pathway.renditions.first?.url?.absoluteString
                == "https://audio.example/override.m3u8"
        )
    }

    @Test("offline planning follows the same preferred pathway")
    func offlinePlanningUsesSteeringCatalog() async throws {
        let urls = try makeContentSteeringURLs()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerContentSteeringMaster(
            at: urls.master,
            steeringURL: urls.steering
        )
        registerContentSteeringManifest(at: urls.steering)
        registerContentSteeringMediaPlaylist(at: urls.cloneMedia)

        let preparation = try await HLSOfflinePackageDownloader(
            session: session
        ).prepare(sourceURL: urls.master)

        #expect(preparation.selectedVariant?.pathwayID == "B")
    }

    @Test("offline steering requires stable identifiers")
    func offlineSteeringRejectsMissingStableIdentifiers() async throws {
        let urls = try makeContentSteeringURLs()
        let session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-CONTENT-STEERING:SERVER-URI="\(urls.steering.absoluteString)",PATHWAY-ID="A"
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,PATHWAY-ID="A"
                    a.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: urls.master
        )
        registerContentSteeringManifest(at: urls.steering)

        await #expect(throws: HLSDownloadError.invalidPlaylist) {
            try await HLSOfflinePackageDownloader(
                session: session
            ).prepare(sourceURL: urls.master)
        }
    }

    @Test("optional I-frame groups do not tighten default offline steering")
    func optionalIFrameGroupsPreserveDefaultSteering() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/optional-iframe/master.m3u8")
        )
        let primaryURL = try #require(
            URL(string: "https://media.example/optional-iframe/video.m3u8")
        )
        let manifest = Data(
            """
            {
              "VERSION": 1,
              "TTL": 30,
              "PATHWAY-PRIORITY": ["A"]
            }
            """.utf8
        )
        let steeringURL = try #require(
            URL(
                string:
                    "data:application/json;base64,"
                    + manifest.base64EncodedString()
            )
        )
        func registerFixtures() {
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: Data(
                        """
                        #EXTM3U
                        #EXT-X-CONTENT-STEERING:SERVER-URI="\(steeringURL.absoluteString)",PATHWAY-ID="A"
                        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="trick",NAME="Angle",URI="trick-angle.m3u8"
                        #EXT-X-STREAM-INF:BANDWIDTH=1000,STABLE-VARIANT-ID="video.main",PATHWAY-ID="A"
                        video.m3u8
                        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,VIDEO="trick",STABLE-VARIANT-ID="iframe.main",PATHWAY-ID="A",URI="iframe.m3u8"

                        """.utf8
                    ),
                    headers: [:]
                ),
                for: masterURL
            )
            HLSURLProtocol.register(
                .success(
                    statusCode: 200,
                    data: Data(
                        """
                        #EXTM3U
                        #EXTINF:1,
                        video.ts
                        #EXT-X-ENDLIST

                        """.utf8
                    ),
                    headers: [:]
                ),
                for: primaryURL
            )
        }

        var session = makeContentSteeringSession()
        registerFixtures()
        let preparation = try await HLSOfflinePackageDownloader(
            session: session
        ).prepare(sourceURL: masterURL)
        #expect(preparation.selectedVariant?.stableID == "video.main")
        #expect(preparation.selectedIFrameVariant == nil)
        session.invalidateAndCancel()
        HLSURLProtocol.reset()

        session = makeContentSteeringSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        registerFixtures()
        await #expect(throws: HLSDownloadError.invalidPlaylist) {
            try await HLSOfflinePackageDownloader(
                session: session,
                configuration: .advanced(
                    renditions: HLSOfflineRenditionPack(
                        includesIFrameTrickPlay: true
                    )
                )
            ).prepare(sourceURL: masterURL)
        }
        #expect(HLSURLProtocol.capturedRequests().count == 1)
    }

    private func makeContentSteeringSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeContentSteeringURLs() throws
        -> ContentSteeringURLs
    {
        try ContentSteeringURLs(
            master: #require(
                URL(string: "https://media.example/master.m3u8")
            ),
            steering: #require(
                URL(string: "https://steering.example/manifest.json")
            ),
            baseMedia: #require(
                URL(string: "https://media.example/a.m3u8")
            ),
            cloneMedia: #require(
                URL(string: "https://edge.example/a.m3u8?token=clone")
            )
        )
    }

    private func makeContentSteeringTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetworkHLSContentSteeringTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func registerContentSteeringMaster(
        at url: URL,
        steeringURL: URL
    ) {
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-VERSION:12
                    #EXT-X-CONTENT-STEERING:SERVER-URI="\(steeringURL.absoluteString)",PATHWAY-ID="A"
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,HDCP-LEVEL=TYPE-1,ALLOWED-CPC="com.example.drm:HW",REQ-VIDEO-LAYOUT="CH-STEREO/PROJ-HEQU",PATHWAY-ID="A",STABLE-VARIANT-ID="video-main"
                    a.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: url
        )
    }

    private func registerContentSteeringManifest(at url: URL) {
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: contentSteeringManifestData(),
                headers: ["Content-Type": "application/json"]
            ),
            for: url
        )
    }

    private func registerContentSteeringMediaPlaylist(at url: URL) {
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: url
        )
    }

    private func contentSteeringManifestData() -> Data {
        Data(
            """
            {
              "VERSION": 1,
              "TTL": 30,
              "PATHWAY-PRIORITY": ["B", "A"],
              "PATHWAY-CLONES": [{
                "BASE-ID": "A",
                "ID": "B",
                "URI-REPLACEMENT": {
                  "HOST": "edge.example",
                  "PARAMS": {"token": "clone"}
                }
              }]
            }
            """.utf8
        )
    }

    private struct ContentSteeringURLs {
        let master: URL
        let steering: URL
        let baseMedia: URL
        let cloneMedia: URL
    }
}

private actor HLSContentSteeringEventRecorder:
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

private final class HLSContentSteeringTestClock: InnoNetworkClock {
    private let observationTime = OSAllocatedUnfairLock<Date>(
        initialState: Date(timeIntervalSince1970: 1_000)
    )

    func sleep(for duration: Duration) async throws {}

    func now() -> Date {
        observationTime.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        observationTime.withLock {
            $0.addTimeInterval(seconds)
        }
    }
}
