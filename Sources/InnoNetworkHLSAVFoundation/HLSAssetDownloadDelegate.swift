#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import InnoNetwork
import os

@available(watchOS 10.0, *)
final class HLSAssetDownloadDelegate: NSObject, AVAssetDownloadDelegate {
    private let eventHub: HLSAssetDownloadEventHub
    private let backgroundCompletions: HLSAssetDownloadBackgroundCompletionStore
    private let invalidationGate: HLSAssetDownloadInvalidationGate
    private let onInvalidation: @Sendable () -> Void

    init(
        eventHub: HLSAssetDownloadEventHub,
        backgroundCompletions:
            HLSAssetDownloadBackgroundCompletionStore,
        invalidationGate: HLSAssetDownloadInvalidationGate,
        onInvalidation: @escaping @Sendable () -> Void
    ) {
        self.eventHub = eventHub
        self.backgroundCompletions = backgroundCompletions
        self.invalidationGate = invalidationGate
        self.onInvalidation = onInvalidation
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        eventHub.sendLocation(
            location,
            taskIdentifier: assetDownloadTask.taskIdentifier
        )
    }

    #if !os(watchOS)
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expectedDuration = CMTimeGetSeconds(
            timeRangeExpectedToLoad.duration
        )
        guard expectedDuration.isFinite, expectedDuration > 0 else {
            return
        }
        let loadedDuration = loadedTimeRanges.reduce(0.0) {
            partialResult,
            value in
            let duration = CMTimeGetSeconds(value.timeRangeValue.duration)
            guard duration.isFinite, duration > 0 else {
                return partialResult
            }
            return partialResult + duration
        }
        eventHub.sendProgress(
            loadedDuration / expectedDuration,
            taskIdentifier: assetDownloadTask.taskIdentifier
        )
    }

    #endif

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else {
            eventHub.sendCompletion(
                taskIdentifier: task.taskIdentifier
            )
            return
        }
        if Self.isCancellation(error) {
            eventHub.sendTerminal(
                .cancelled,
                taskIdentifier: task.taskIdentifier
            )
        } else {
            eventHub.sendTerminal(
                .failed(SendableUnderlyingError(error)),
                taskIdentifier: task.taskIdentifier
            )
        }
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        backgroundCompletions.takeAll().forEach { completion in
            completion()
        }
    }

    func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: (any Error)?
    ) {
        if let error {
            eventHub.failSession(
                SendableUnderlyingError(error)
            )
        }
        invalidationGate.complete()
        onInvalidation()
    }

    static func isCancellation(_ error: any Error) -> Bool {
        let cocoaError = error as NSError
        return
            (cocoaError.domain == NSURLErrorDomain
            && cocoaError.code == NSURLErrorCancelled)
            || (cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code
                    == CocoaError.Code.userCancelled.rawValue)
    }
}

@available(macOS 14.0, iOS 16.0, watchOS 10.0, visionOS 1.0, *)
extension HLSAssetDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadVariants variants: [AVAssetVariant]
    ) {
        eventHub.sendVariantSelection(
            HLSAssetDownloadVariantSelection(variants),
            taskIdentifier: assetDownloadTask.taskIdentifier
        )
    }
}

@available(macOS 14.0, iOS 18.0, watchOS 10.0, visionOS 1.0, *)
extension HLSAssetDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        eventHub.sendLocation(
            location,
            taskIdentifier: assetDownloadTask.taskIdentifier
        )
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension HLSAssetDownloadDelegate {
    // AVFoundation invokes this optional delegate entry point dynamically.
    // periphery:ignore
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didReceiveMetricEvent metricEvent: AVMetricEvent
    ) {
        guard
            let summary = HLSAssetDownloadMetricMapper.map(metricEvent)
        else {
            return
        }
        eventHub.sendSummary(
            summary,
            taskIdentifier: assetDownloadTask.taskIdentifier
        )
    }
}

final class HLSAssetDownloadBackgroundCompletionStore: Sendable {
    private let completions = OSAllocatedUnfairLock<
        [@Sendable () -> Void]
    >(initialState: [])

    func set(_ completion: @escaping @Sendable () -> Void) {
        completions.withLock {
            $0.append(completion)
        }
    }

    func takeAll() -> [@Sendable () -> Void] {
        completions.withLock { completions in
            let pending = completions
            completions.removeAll(keepingCapacity: true)
            return pending
        }
    }
}

final class HLSAssetDownloadInvalidationGate: Sendable {
    private struct State {
        var continuations: [CheckedContinuation<Void, Never>] = []
        var isComplete = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isComplete else {
                    return true
                }
                state.continuations.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func complete() {
        let continuations: [CheckedContinuation<Void, Never>] =
            state.withLock { state in
                guard !state.isComplete else {
                    return []
                }
                state.isComplete = true
                let continuations = state.continuations
                state.continuations.removeAll()
                return continuations
            }
        continuations.forEach {
            $0.resume()
        }
    }
}
#endif
