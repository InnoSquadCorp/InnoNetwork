#if canImport(AVFoundation) && !os(tvOS)
import Foundation
import InnoNetwork
import os

final class HLSAssetDownloadEventHub: Sendable {
    private static let maximumRetainedTerminalEvents = 256

    private typealias Continuation =
        AsyncStream<HLSAssetDownloadEvent>.Continuation

    private struct Observer {
        let id: UUID
        let continuation: Continuation
    }

    private struct State {
        var observers: [Int: [Observer]] = [:]
        var variantSelections: [Int: HLSAssetDownloadVariantSelection] = [:]
        var locations: [Int: URL] = [:]
        var progress: [Int: Double] = [:]
        var summaries: [Int: HLSAssetDownloadSummary] = [:]
        var terminalEvents: [Int: HLSAssetDownloadEvent] = [:]
        var terminalTaskOrder: [Int] = []
        var sessionFailure: HLSAssetDownloadEvent?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func stream(
        taskIdentifier: Int
    ) -> AsyncStream<HLSAssetDownloadEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) {
            continuation in
            let observerID = UUID()
            // Yield the snapshot while the hub lock excludes live delivery,
            // then install termination cleanup after releasing the lock so
            // a finished continuation cannot re-enter `removeObserver`.
            let shouldFinish = state.withLock { state in
                if let sessionFailure = state.sessionFailure {
                    continuation.yield(sessionFailure)
                    return true
                }
                if let selection = state.variantSelections[taskIdentifier] {
                    continuation.yield(.variantSelection(selection))
                }
                if let progress = state.progress[taskIdentifier] {
                    continuation.yield(.progress(progress))
                }
                if let location = state.locations[taskIdentifier] {
                    continuation.yield(.locationAvailable(location))
                }
                if let summary = state.summaries[taskIdentifier] {
                    continuation.yield(.downloadSummary(summary))
                }
                if let terminal = state.terminalEvents[taskIdentifier] {
                    continuation.yield(terminal)
                    return true
                }
                state.observers[taskIdentifier, default: []].append(
                    Observer(
                        id: observerID,
                        continuation: continuation
                    )
                )
                return false
            }
            if shouldFinish {
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeObserver(
                    observerID,
                    taskIdentifier: taskIdentifier
                )
            }
        }
    }

    func sendVariantSelection(
        _ selection: HLSAssetDownloadVariantSelection,
        taskIdentifier: Int
    ) {
        let continuations: [Continuation] = state.withLock { state in
            guard state.terminalEvents[taskIdentifier] == nil,
                state.sessionFailure == nil
            else {
                return []
            }
            let previous = state.variantSelections.updateValue(
                selection,
                forKey: taskIdentifier
            )
            guard previous != selection else {
                return []
            }
            return state.observers[taskIdentifier, default: []].map(
                \.continuation
            )
        }
        continuations.forEach {
            $0.yield(.variantSelection(selection))
        }
    }

    func sendProgress(
        _ fractionCompleted: Double,
        taskIdentifier: Int
    ) {
        let fraction = min(1, max(0, fractionCompleted))
        let continuations: [Continuation] = state.withLock { state in
            guard state.terminalEvents[taskIdentifier] == nil,
                state.sessionFailure == nil
            else {
                return []
            }
            state.progress[taskIdentifier] = fraction
            return state.observers[taskIdentifier, default: []].map(
                \.continuation
            )
        }
        continuations.forEach {
            $0.yield(.progress(fraction))
        }
    }

    func sendLocation(
        _ location: URL,
        taskIdentifier: Int
    ) {
        let continuations: [Continuation] = state.withLock { state in
            guard state.terminalEvents[taskIdentifier] == nil,
                state.sessionFailure == nil
            else {
                return []
            }
            let previousLocation = state.locations.updateValue(
                location,
                forKey: taskIdentifier
            )
            guard previousLocation != location else {
                return []
            }
            return state.observers[taskIdentifier, default: []].map(
                \.continuation
            )
        }
        continuations.forEach {
            $0.yield(.locationAvailable(location))
        }
    }

    func sendSummary(
        _ summary: HLSAssetDownloadSummary,
        taskIdentifier: Int
    ) {
        let continuations: [Continuation] = state.withLock { state in
            guard state.terminalEvents[taskIdentifier] == nil,
                state.sessionFailure == nil
            else {
                return []
            }
            let previous = state.summaries.updateValue(
                summary,
                forKey: taskIdentifier
            )
            guard previous != summary else {
                return []
            }
            return state.observers[taskIdentifier, default: []].map(
                \.continuation
            )
        }
        continuations.forEach {
            $0.yield(.downloadSummary(summary))
        }
    }

    func sendCompletion(taskIdentifier: Int) {
        let event = state.withLock { state -> HLSAssetDownloadEvent in
            guard let location = state.locations[taskIdentifier] else {
                return .failed(
                    SendableUnderlyingError(
                        domain:
                            "InnoNetworkHLSAVFoundation.AssetDownload",
                        code: 1,
                        message:
                            "AVFoundation completed without providing a system-managed asset URL."
                    )
                )
            }
            return .completed(location)
        }
        sendTerminal(event, taskIdentifier: taskIdentifier)
    }

    func sendTerminal(
        _ event: HLSAssetDownloadEvent,
        taskIdentifier: Int
    ) {
        let continuations: [Continuation] = state.withLock { state in
            guard state.terminalEvents[taskIdentifier] == nil,
                state.sessionFailure == nil
            else {
                return []
            }
            state.terminalEvents[taskIdentifier] = event
            state.terminalTaskOrder.append(taskIdentifier)
            while state.terminalTaskOrder.count
                > Self.maximumRetainedTerminalEvents
            {
                let evictedTaskIdentifier =
                    state.terminalTaskOrder.removeFirst()
                state.terminalEvents.removeValue(
                    forKey: evictedTaskIdentifier
                )
                state.locations.removeValue(
                    forKey: evictedTaskIdentifier
                )
                state.variantSelections.removeValue(
                    forKey: evictedTaskIdentifier
                )
                state.progress.removeValue(
                    forKey: evictedTaskIdentifier
                )
                state.summaries.removeValue(
                    forKey: evictedTaskIdentifier
                )
            }
            state.progress.removeValue(forKey: taskIdentifier)
            return state.observers.removeValue(
                forKey: taskIdentifier
            )?.map(\.continuation) ?? []
        }
        continuations.forEach {
            $0.yield(event)
            $0.finish()
        }
    }

    func failSession(_ error: SendableUnderlyingError?) {
        let event = HLSAssetDownloadEvent.failed(
            error
                ?? SendableUnderlyingError(
                    domain:
                        "InnoNetworkHLSAVFoundation.AssetDownloadSession",
                    code: 1,
                    message:
                        "The AVFoundation asset download session was invalidated."
                )
        )
        let continuations: [Continuation] = state.withLock { state in
            guard state.sessionFailure == nil else {
                return []
            }
            state.sessionFailure = event
            let continuations = state.observers.values
                .flatMap { $0 }
                .map(\.continuation)
            state.observers.removeAll()
            state.variantSelections.removeAll()
            state.locations.removeAll()
            state.progress.removeAll()
            state.summaries.removeAll()
            state.terminalEvents.removeAll()
            state.terminalTaskOrder.removeAll()
            return continuations
        }
        continuations.forEach {
            $0.yield(event)
            $0.finish()
        }
    }

    func location(taskIdentifier: Int) -> URL? {
        state.withLock { $0.locations[taskIdentifier] }
    }

    var retainedTerminalEventCount: Int {
        state.withLock { $0.terminalEvents.count }
    }

    private func removeObserver(
        _ observerID: UUID,
        taskIdentifier: Int
    ) {
        state.withLock { state in
            state.observers[taskIdentifier]?.removeAll {
                $0.id == observerID
            }
            if state.observers[taskIdentifier]?.isEmpty == true {
                state.observers.removeValue(forKey: taskIdentifier)
            }
        }
    }
}
#endif
