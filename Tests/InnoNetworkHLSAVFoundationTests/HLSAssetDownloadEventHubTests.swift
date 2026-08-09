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
