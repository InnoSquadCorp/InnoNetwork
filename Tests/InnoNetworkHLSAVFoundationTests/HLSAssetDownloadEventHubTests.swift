#if canImport(AVFoundation) && !os(tvOS)
import Foundation
import Testing
import os

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS event hub")
struct HLSAssetDownloadEventHubTests {
    @Test("location and completion are replayed to late observers")
    func terminalReplay() async throws {
        let hub = HLSAssetDownloadEventHub()
        let taskIdentifier = 42
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset.movpkg")
        hub.sendLocation(location, taskIdentifier: taskIdentifier)
        hub.sendCompletion(taskIdentifier: taskIdentifier)

        var events: [HLSAssetDownloadEvent] = []
        for await event in hub.stream(
            taskIdentifier: taskIdentifier
        ) {
            events.append(event)
        }

        #expect(events.count == 2)
        guard case .locationAvailable(location) = events[0] else {
            Issue.record("Expected a replayed location.")
            return
        }
        guard case .completed(location) = events[1] else {
            Issue.record("Expected a replayed completion.")
            return
        }
    }

    @Test("progress is clamped and completion closes observers")
    func progressAndCompletion() async throws {
        let hub = HLSAssetDownloadEventHub()
        let taskIdentifier = 7
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset.movpkg")
        let stream = hub.stream(taskIdentifier: taskIdentifier)

        hub.sendProgress(1.5, taskIdentifier: taskIdentifier)
        hub.sendLocation(location, taskIdentifier: taskIdentifier)
        hub.sendCompletion(taskIdentifier: taskIdentifier)

        var events: [HLSAssetDownloadEvent] = []
        for await event in stream {
            events.append(event)
        }

        guard case .progress(let progress) = events.first else {
            Issue.record("Expected progress first.")
            return
        }
        #expect(progress == 1)
        #expect(events.count == 3)
    }

    @Test("download summaries are delivered and replayed before completion")
    func downloadSummaryReplay() async throws {
        let hub = HLSAssetDownloadEventHub()
        let taskIdentifier = 8
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary.movpkg")
        let summary = HLSAssetDownloadSummary(
            date: Date(timeIntervalSince1970: 3_000),
            recoverableErrorCount: 0,
            mediaResourceRequestCount: 4,
            bytesDownloaded: 8_192,
            downloadDuration: 3,
            variants: [],
            hadError: false
        )
        let liveStream = hub.stream(taskIdentifier: taskIdentifier)
        hub.sendLocation(location, taskIdentifier: taskIdentifier)
        hub.sendSummary(summary, taskIdentifier: taskIdentifier)
        hub.sendCompletion(taskIdentifier: taskIdentifier)

        var liveEvents: [HLSAssetDownloadEvent] = []
        for await event in liveStream {
            liveEvents.append(event)
        }
        var replayedEvents: [HLSAssetDownloadEvent] = []
        for await event in hub.stream(
            taskIdentifier: taskIdentifier
        ) {
            replayedEvents.append(event)
        }

        for events in [liveEvents, replayedEvents] {
            #expect(events.count == 3)
            guard case .downloadSummary(summary) = events[1] else {
                Issue.record("Expected a download summary.")
                return
            }
            #expect(summary.bytesDownloaded == 8_192)
            guard case .completed(location) = events[2] else {
                Issue.record("Expected completion after the summary.")
                return
            }
        }
    }

    @Test("variant selection is deduplicated and replayed before progress")
    func variantSelectionReplay() async throws {
        let hub = HLSAssetDownloadEventHub()
        let taskIdentifier = 9
        let selection = HLSAssetDownloadVariantSelection(
            variants: [
                HLSAssetDownloadVariantSummary(
                    peakBitRate: 4_000_000,
                    averageBitRate: 3_000_000,
                    hasVideo: true,
                    hasAudio: true
                )
            ]
        )
        let liveStream = hub.stream(taskIdentifier: taskIdentifier)
        hub.sendVariantSelection(
            selection,
            taskIdentifier: taskIdentifier
        )
        hub.sendVariantSelection(
            selection,
            taskIdentifier: taskIdentifier
        )
        hub.sendProgress(0.25, taskIdentifier: taskIdentifier)
        hub.sendTerminal(
            .cancelled,
            taskIdentifier: taskIdentifier
        )

        var liveEvents: [HLSAssetDownloadEvent] = []
        for await event in liveStream {
            liveEvents.append(event)
        }
        var replayedEvents: [HLSAssetDownloadEvent] = []
        for await event in hub.stream(taskIdentifier: taskIdentifier) {
            replayedEvents.append(event)
        }

        #expect(liveEvents.count == 3)
        guard case .variantSelection(let liveSelection) = liveEvents[0] else {
            Issue.record("Expected live variant selection first.")
            return
        }
        #expect(liveSelection == selection)
        guard case .progress(0.25) = liveEvents[1] else {
            Issue.record("Expected progress after live variant selection.")
            return
        }
        guard case .cancelled = liveEvents[2] else {
            Issue.record("Expected live terminal cancellation.")
            return
        }

        #expect(replayedEvents.count == 2)
        guard
            case .variantSelection(let replayedSelection) =
                replayedEvents[0]
        else {
            Issue.record("Expected replayed variant selection first.")
            return
        }
        #expect(replayedSelection == selection)
        guard case .cancelled = replayedEvents[1] else {
            Issue.record("Expected replayed terminal cancellation.")
            return
        }
    }

    @Test("terminal replay storage stays bounded")
    func boundedTerminalReplayStorage() {
        let hub = HLSAssetDownloadEventHub()
        for taskIdentifier in 0..<300 {
            hub.sendTerminal(
                .cancelled,
                taskIdentifier: taskIdentifier
            )
        }

        #expect(hub.retainedTerminalEventCount == 256)
    }

    @Test("all pending background completions are drained together")
    func backgroundCompletionDrain() {
        let store = HLSAssetDownloadBackgroundCompletionStore()
        let completionCount = OSAllocatedUnfairLock(initialState: 0)

        store.set {
            completionCount.withLock { $0 += 1 }
        }
        store.set {
            completionCount.withLock { $0 += 1 }
        }

        let pending = store.takeAll()
        pending.forEach { $0() }

        #expect(completionCount.withLock { $0 } == 2)
        #expect(store.takeAll().isEmpty)
    }
}
#endif
