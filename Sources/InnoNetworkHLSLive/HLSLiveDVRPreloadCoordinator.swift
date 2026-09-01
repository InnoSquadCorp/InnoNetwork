import Foundation
import InnoNetworkHLS

actor HLSLiveDVRPreloadCoordinator {
    private enum Kind: Equatable, Sendable {
        case partialSegment
        case initializationMap
    }

    private enum RequestRange: Equatable, Sendable {
        case complete
        case exact(HLSByteRange)
        case openEnded(Int64)
    }

    private struct Target: Equatable, Sendable {
        let kind: Kind
        let url: URL
        let requestRange: RequestRange
        let context: HLSLowLatencyResourceContext

        var exactByteRange: HLSByteRange? {
            guard case .exact(let byteRange) = requestRange else {
                return nil
            }
            return byteRange
        }
    }

    private struct PreloadedResource: Sendable {
        let fileURL: URL
        let byteCount: Int64
    }

    private enum PreloadOutcome: Sendable {
        case loaded(PreloadedResource)
        case failed
        case cancelled
    }

    private struct Entry: Sendable {
        let target: Target
        let reservedBytes: Int64
        let task: Task<PreloadOutcome, Never>
        var verifiedTarget: Target?
        var wasConfirmed: Bool
    }

    private struct Counters {
        var requestCount = 0
        var completedCount = 0
        var confirmedCount = 0
        var reuseCount = 0
        var missCount = 0
        var failureCount = 0
        var cancellationCount = 0
        var discardCount = 0
        var transferredByteCount: Int64 = 0
        var reusedByteCount: Int64 = 0
        var discardedByteCount: Int64 = 0

        mutating func increment(
            _ keyPath: WritableKeyPath<Self, Int>
        ) {
            let value = self[keyPath: keyPath]
            self[keyPath: keyPath] =
                value == .max ? .max : value + 1
        }

        mutating func add(
            _ byteCount: Int64,
            to keyPath: WritableKeyPath<Self, Int64>
        ) {
            let (value, overflow) = self[keyPath: keyPath]
                .addingReportingOverflow(byteCount)
            self[keyPath: keyPath] = overflow ? .max : value
        }

        var snapshot: HLSLiveDVRPreloadResourceStatistics {
            HLSLiveDVRPreloadResourceStatistics(
                requestCount: requestCount,
                completedCount: completedCount,
                confirmedCount: confirmedCount,
                reuseCount: reuseCount,
                missCount: missCount,
                failureCount: failureCount,
                cancellationCount: cancellationCount,
                discardCount: discardCount,
                transferredByteCount: transferredByteCount,
                reusedByteCount: reusedByteCount,
                discardedByteCount: discardedByteCount
            )
        }
    }

    private let pack: HLSLiveDVRPreloadPack
    private let parts: HLSLiveDVRPartPack
    private let resourceLoader: HLSLiveDVRResourceLoader
    private let context: HLSLiveDVRResourceContext
    private let directoryURL: URL
    private let maximumMediaResourceBytes: Int
    private var entries: [Entry] = []
    private var partialSegmentCounters = Counters()
    private var initializationMapCounters = Counters()

    init(
        pack: HLSLiveDVRPreloadPack,
        parts: HLSLiveDVRPartPack,
        resourceLoader: HLSLiveDVRResourceLoader,
        context: HLSLiveDVRResourceContext,
        workspace: HLSLiveDVRWorkspace,
        maximumMediaResourceBytes: Int
    ) {
        self.pack = pack
        self.parts = parts
        self.resourceLoader = resourceLoader
        self.context = context
        self.directoryURL = workspace.directoryURL
            .appendingPathComponent("preload", isDirectory: true)
        self.maximumMediaResourceBytes = maximumMediaResourceBytes
    }

    func statisticsSnapshot() -> HLSLiveDVRPreloadStatistics {
        HLSLiveDVRPreloadStatistics(
            partialSegments: partialSegmentCounters.snapshot,
            initializationMaps: initializationMapCounters.snapshot
        )
    }

    func update(from snapshot: HLSLivePlaylistSnapshot) async {
        guard pack.policy == .unencryptedMedia,
            !snapshot.isDeltaUpdate,
            snapshot.encryptionMethod == nil
        else {
            _ = await cancelAll()
            return
        }

        let actualTargets = actualTargets(from: snapshot)
        let hintedTargets =
            snapshot.isEnded
            ? []
            : hintedTargets(from: snapshot)
        var retained: [Entry] = []
        var discarded: [Entry] = []
        for var entry in entries {
            if let actual = actualTargets.first(where: {
                Self.matches(hint: entry.target, actual: $0)
            }) {
                if !entry.wasConfirmed {
                    recordConfirmation(for: entry.target.kind)
                    entry.wasConfirmed = true
                }
                entry.verifiedTarget = actual
            } else if let verified = entry.verifiedTarget,
                !actualTargets.contains(verified)
            {
                entry.verifiedTarget = nil
            }
            let remainsHinted = hintedTargets.contains(entry.target)
            let remainsVerified = entry.verifiedTarget != nil
            if remainsHinted || remainsVerified {
                retained.append(entry)
            } else {
                discarded.append(entry)
            }
        }
        entries = retained
        await discard(discarded)

        for target in hintedTargets
        where !entries.contains(where: { $0.target == target }) {
            schedule(target)
        }
    }

    func consume(
        _ part: HLSLivePartialSegment,
        to destinationURL: URL,
        maximumRetainedBytes: Int64
    ) async -> Int64? {
        guard let context = part.resourceContext else {
            recordMiss(for: .partialSegment)
            return nil
        }
        let actual = Target(
            kind: .partialSegment,
            url: part.url,
            requestRange: part.byteRange.map(RequestRange.exact)
                ?? .complete,
            context: context
        )
        return await consume(
            actual,
            to: destinationURL,
            maximumRetainedBytes: maximumRetainedBytes
        )
    }

    func consume(
        _ initialization: HLSLiveInitializationSegment,
        to destinationURL: URL,
        maximumRetainedBytes: Int64
    ) async -> Int64? {
        guard
            let index = entries.firstIndex(where: {
                $0.target.kind == .initializationMap
                    && $0.target.url == initialization.url
                    && $0.verifiedTarget != nil
                    && Self.matches(
                        requestRange: $0.target.requestRange,
                        actualByteRange: initialization.byteRange
                    )
            })
        else {
            recordMiss(for: .initializationMap)
            return nil
        }
        return await consume(
            at: index,
            actualByteRange: initialization.byteRange,
            to: destinationURL,
            maximumRetainedBytes: maximumRetainedBytes
        )
    }

    @discardableResult
    func cancelAll() async -> HLSLiveDVRPreloadStatistics {
        let discarded = entries
        entries.removeAll(keepingCapacity: false)
        await discard(discarded)
        try? FileManager.default.removeItem(at: directoryURL)
        return statisticsSnapshot()
    }

    private func consume(
        _ actual: Target,
        to destinationURL: URL,
        maximumRetainedBytes: Int64
    ) async -> Int64? {
        guard
            let index = entries.firstIndex(where: {
                guard let verified = $0.verifiedTarget else {
                    return false
                }
                return Self.matches(hint: $0.target, actual: actual)
                    && verified == actual
            })
        else {
            recordMiss(for: actual.kind)
            return nil
        }
        let actualByteRange: HLSByteRange?
        switch actual.requestRange {
        case .complete, .openEnded:
            actualByteRange = nil
        case .exact(let byteRange):
            actualByteRange = byteRange
        }
        return await consume(
            at: index,
            actualByteRange: actualByteRange,
            to: destinationURL,
            maximumRetainedBytes: maximumRetainedBytes
        )
    }

    private func consume(
        at index: Int,
        actualByteRange: HLSByteRange?,
        to destinationURL: URL,
        maximumRetainedBytes: Int64
    ) async -> Int64? {
        let entry = entries.remove(at: index)
        let outcome = await entry.task.value
        record(outcome, for: entry.target.kind)
        guard case .loaded(let resource) = outcome,
            resource.byteCount <= maximumRetainedBytes,
            Self.matches(
                requestRange: entry.target.requestRange,
                actualByteRange: actualByteRange,
                transferredByteCount: resource.byteCount
            )
        else {
            if case .loaded(let resource) = outcome {
                try? FileManager.default.removeItem(at: resource.fileURL)
                recordDiscard(
                    byteCount: resource.byteCount,
                    for: entry.target.kind
                )
            } else {
                recordDiscard(byteCount: 0, for: entry.target.kind)
            }
            recordMiss(for: entry.target.kind)
            return nil
        }
        do {
            try FileManager.default.moveItem(
                at: resource.fileURL,
                to: destinationURL
            )
            recordReuse(
                byteCount: resource.byteCount,
                for: entry.target.kind
            )
            return resource.byteCount
        } catch {
            try? FileManager.default.removeItem(at: resource.fileURL)
            recordDiscard(
                byteCount: resource.byteCount,
                for: entry.target.kind
            )
            recordMiss(for: entry.target.kind)
            return nil
        }
    }

    private func schedule(_ target: Target) {
        let reserved = entries.reduce(Int64(0)) {
            $0 + $1.reservedBytes
        }
        let remaining = max(0, pack.maximumTotalBytes - reserved)
        let maximumBytes64 = min(
            remaining,
            Int64(pack.maximumResourceBytes),
            Int64(maximumMediaResourceBytes),
            Int64(Int.max)
        )
        guard maximumBytes64 > 0 else {
            return
        }
        if case .exact(let byteRange) = target.requestRange,
            byteRange.length > maximumBytes64
        {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return
        }
        let fileURL = directoryURL.appendingPathComponent(
            UUID().uuidString
        )
        let loader = resourceLoader
        let context = context
        let task = Task<PreloadOutcome, Never> {
            do {
                let exactByteRange: HLSByteRange?
                let openEndedByteRangeStart: Int64?
                switch target.requestRange {
                case .complete:
                    exactByteRange = nil
                    openEndedByteRangeStart = nil
                case .exact(let byteRange):
                    exactByteRange = byteRange
                    openEndedByteRangeStart = nil
                case .openEnded(let start):
                    exactByteRange = nil
                    openEndedByteRangeStart = start
                }
                let byteCount = try await loader.load(
                    from: target.url,
                    byteRange: exactByteRange,
                    openEndedByteRangeStart:
                        openEndedByteRangeStart,
                    encryption: nil,
                    purpose: .mediaPreloadHint,
                    resourceIndex: nil,
                    maximumBytes: Int(maximumBytes64),
                    maximumRetainedBytes: Int(maximumBytes64),
                    keyCache: context.keyCache,
                    diskCapacityGuard: context.diskCapacityGuard,
                    destinationURL: fileURL
                )
                return .loaded(
                    PreloadedResource(
                        fileURL: fileURL,
                        byteCount: byteCount
                    )
                )
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                return Self.isCancellation(error) ? .cancelled : .failed
            }
        }
        recordRequest(for: target.kind)
        entries.append(
            Entry(
                target: target,
                reservedBytes: maximumBytes64,
                task: task,
                verifiedTarget: nil,
                wasConfirmed: false
            )
        )
    }

    private func discard(_ discarded: [Entry]) async {
        for entry in discarded {
            entry.task.cancel()
        }
        for entry in discarded {
            let outcome = await entry.task.value
            record(outcome, for: entry.target.kind)
            if case .loaded(let resource) = outcome {
                try? FileManager.default.removeItem(at: resource.fileURL)
                recordDiscard(
                    byteCount: resource.byteCount,
                    for: entry.target.kind
                )
            } else {
                recordDiscard(byteCount: 0, for: entry.target.kind)
            }
        }
    }

    private func recordRequest(for kind: Kind) {
        updateCounters(for: kind) {
            $0.increment(\.requestCount)
        }
    }

    private func recordConfirmation(for kind: Kind) {
        updateCounters(for: kind) {
            $0.increment(\.confirmedCount)
        }
    }

    private func recordReuse(byteCount: Int64, for kind: Kind) {
        updateCounters(for: kind) {
            $0.increment(\.reuseCount)
            $0.add(byteCount, to: \.reusedByteCount)
        }
    }

    private func recordMiss(for kind: Kind) {
        updateCounters(for: kind) {
            $0.increment(\.missCount)
        }
    }

    private func recordDiscard(byteCount: Int64, for kind: Kind) {
        updateCounters(for: kind) {
            $0.increment(\.discardCount)
            $0.add(byteCount, to: \.discardedByteCount)
        }
    }

    private func record(_ outcome: PreloadOutcome, for kind: Kind) {
        updateCounters(for: kind) {
            switch outcome {
            case .loaded(let resource):
                $0.increment(\.completedCount)
                $0.add(resource.byteCount, to: \.transferredByteCount)
            case .failed:
                $0.increment(\.failureCount)
            case .cancelled:
                $0.increment(\.cancellationCount)
            }
        }
    }

    private func updateCounters(
        for kind: Kind,
        _ update: (inout Counters) -> Void
    ) {
        switch kind {
        case .partialSegment:
            update(&partialSegmentCounters)
        case .initializationMap:
            update(&initializationMapCounters)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let error = error as NSError
        return error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled
    }

    private func hintedTargets(
        from snapshot: HLSLivePlaylistSnapshot
    ) -> [Target] {
        snapshot.playlist.lowLatency?.preloadHints.compactMap {
            hint in
            guard let context = hint.resourceContext,
                context.encryption == nil
            else {
                return nil
            }
            let kind: Kind
            switch hint.type {
            case .partialSegment:
                guard parts.policy == .independent else {
                    return nil
                }
                kind = .partialSegment
            case .initializationMap:
                kind = .initializationMap
            case .encryptionKey:
                return nil
            }
            return Target(
                kind: kind,
                url: hint.url,
                requestRange: Self.requestRange(for: hint),
                context: context
            )
        } ?? []
    }

    private func actualTargets(
        from snapshot: HLSLivePlaylistSnapshot
    ) -> [Target] {
        let parts = snapshot.partialSegments.compactMap { part in
            part.resourceContext.map {
                Target(
                    kind: .partialSegment,
                    url: part.url,
                    requestRange:
                        part.byteRange.map(RequestRange.exact)
                        ?? .complete,
                    context: $0
                )
            }
        }
        let maps =
            snapshot.playlist.lowLatency?.initializationMaps.map {
                initialization in
                Target(
                    kind: .initializationMap,
                    url: initialization.resource.url,
                    requestRange:
                        initialization.resource.byteRange.map(
                            RequestRange.exact
                        ) ?? .complete,
                    context: initialization.context
                )
            } ?? []
        return parts + maps
    }

    private static func requestRange(
        for hint: HLSPreloadHint
    ) -> RequestRange {
        let start = hint.byteRangeStart ?? 0
        if let length = hint.byteRangeLength,
            let byteRange = HLSByteRange(
                offset: start,
                length: length
            )
        {
            return .exact(byteRange)
        }
        if hint.byteRangeStart != nil {
            return .openEnded(start)
        }
        return .complete
    }

    private static func matches(
        hint: Target,
        actual: Target
    ) -> Bool {
        guard hint.kind == actual.kind,
            hint.url == actual.url,
            hint.context.discontinuitySequence
                == actual.context.discontinuitySequence,
            hint.context.encryption == actual.context.encryption,
            matches(
                requestRange: hint.requestRange,
                actualByteRange: actual.exactByteRange
            )
        else {
            return false
        }
        switch hint.kind {
        case .partialSegment:
            return matches(
                hintedInitializationMap:
                    hint.context.initializationMap,
                actualInitializationMap:
                    actual.context.initializationMap
            )
        case .initializationMap:
            return true
        }
    }

    private static func matches(
        hintedInitializationMap:
            HLSLowLatencyResourceIdentity?,
        actualInitializationMap:
            HLSLowLatencyResourceIdentity?
    ) -> Bool {
        guard let hintedInitializationMap else {
            return actualInitializationMap == nil
        }
        guard let actualInitializationMap,
            hintedInitializationMap.url
                == actualInitializationMap.url
        else {
            return false
        }
        if let start = hintedInitializationMap
            .openEndedByteRangeStart
        {
            return actualInitializationMap.byteRange?.offset == start
        }
        return hintedInitializationMap.byteRange
            == actualInitializationMap.byteRange
    }

    private static func matches(
        requestRange: RequestRange,
        actualByteRange: HLSByteRange?,
        transferredByteCount: Int64? = nil
    ) -> Bool {
        switch requestRange {
        case .complete:
            return actualByteRange == nil
        case .exact(let expected):
            return actualByteRange == expected
                && (transferredByteCount == nil
                    || transferredByteCount == expected.length)
        case .openEnded(let start):
            guard let actualByteRange,
                actualByteRange.offset == start
            else {
                return false
            }
            return transferredByteCount == nil
                || transferredByteCount == actualByteRange.length
        }
    }
}
