import Foundation
import InnoNetworkHLS

/// Receives opt-in requests to preload upcoming HLS encryption keys.
///
/// The live client schedules callbacks but never requests or stores key
/// bytes. Implement this protocol in the application or DRM layer that owns
/// key delivery and caching.
public protocol HLSLiveEncryptionKeyPreloading: Sendable {
    /// Starts application-owned preloading for one current key hint.
    func preloadEncryptionKey(
        for hint: HLSPreloadHint
    ) async
}

actor HLSLiveKeyPreloadCoordinator {
    private struct Identity: Hashable {
        let url: URL
        let method: String
        let keyFormat: String
        let keyFormatVersions: [Int]
        let estimatedFirstUseDate: Date?

        func hash(into hasher: inout Hasher) {
            hasher.combine(url)
            hasher.combine(method)
            hasher.combine(keyFormat)
            hasher.combine(keyFormatVersions)
            hasher.combine(estimatedFirstUseDate)
        }
    }

    private struct ScheduledTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let preloader: any HLSLiveEncryptionKeyPreloading
    private let sleep: @Sendable (Duration) async throws -> Void
    private let randomUnitInterval: @Sendable () -> Double
    private var scheduled: [Identity: ScheduledTask] = [:]
    private var completed: Set<Identity> = []

    init(
        preloader: any HLSLiveEncryptionKeyPreloading,
        sleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await ContinuousClock().sleep(for: $0)
            },
        randomUnitInterval:
            @escaping @Sendable () -> Double = {
                Double.random(in: 0...1)
            }
    ) {
        self.preloader = preloader
        self.sleep = sleep
        self.randomUnitInterval = randomUnitInterval
    }

    func update(
        after snapshot: HLSLivePlaylistSnapshot
    ) {
        let hints =
            snapshot.playlist.lowLatency?.preloadHints
            .compactMap { hint -> (Identity, HLSPreloadHint)? in
                guard let key = hint.encryptionKey else {
                    return nil
                }
                return (
                    Identity(
                        url: hint.url,
                        method: key.method,
                        keyFormat: key.keyFormat,
                        keyFormatVersions: key.keyFormatVersions,
                        estimatedFirstUseDate:
                            hint.estimatedFirstUseDate
                    ),
                    hint
                )
            } ?? []
        let currentIdentities = Set(hints.map(\.0))

        let obsoleteIdentities = scheduled.keys.filter {
            !currentIdentities.contains($0)
        }
        for identity in obsoleteIdentities {
            scheduled.removeValue(forKey: identity)?.task.cancel()
        }
        completed.formIntersection(currentIdentities)

        for (identity, hint) in hints
        where scheduled[identity] == nil
            && !completed.contains(identity)
        {
            schedule(
                hint,
                identity: identity,
                after: snapshot
            )
        }
    }

    func cancelAll() {
        for task in scheduled.values {
            task.task.cancel()
        }
        scheduled.removeAll()
        completed.removeAll()
    }

    private func schedule(
        _ hint: HLSPreloadHint,
        identity: Identity,
        after snapshot: HLSLivePlaylistSnapshot
    ) {
        let delay = Self.preloadDelay(
            for: hint,
            after: snapshot,
            randomUnitInterval: randomUnitInterval()
        )
        let token = UUID()
        let task = Task {
            do {
                try await sleep(.seconds(delay))
            } catch {
                finish(
                    identity,
                    token: token,
                    completed: false
                )
                return
            }
            guard !Task.isCancelled else {
                finish(
                    identity,
                    token: token,
                    completed: false
                )
                return
            }
            await preloader.preloadEncryptionKey(for: hint)
            finish(
                identity,
                token: token,
                completed: true
            )
        }
        scheduled[identity] = ScheduledTask(
            token: token,
            task: task
        )
    }

    private func finish(
        _ identity: Identity,
        token: UUID,
        completed didComplete: Bool
    ) {
        guard scheduled[identity]?.token == token else {
            return
        }
        scheduled.removeValue(forKey: identity)
        if didComplete {
            completed.insert(identity)
        }
    }

    private static func preloadDelay(
        for hint: HLSPreloadHint,
        after snapshot: HLSLivePlaylistSnapshot,
        randomUnitInterval: Double
    ) -> TimeInterval {
        guard
            let firstUseDate = hint.estimatedFirstUseDate,
            let liveEdgeDate = estimatedLiveEdgeDate(
                in: snapshot
            )
        else {
            return 0
        }
        let remaining = max(
            0,
            firstUseDate.timeIntervalSince(liveEdgeDate)
        )
        let unitInterval: Double
        if randomUnitInterval.isFinite {
            unitInterval = min(1, max(0, randomUnitInterval))
        } else {
            unitInterval = 0
        }
        return remaining * unitInterval
    }

    private static func estimatedLiveEdgeDate(
        in snapshot: HLSLivePlaylistSnapshot
    ) -> Date? {
        guard
            let anchor = snapshot.playlist.programDateTimes.last,
            let declaredMediaSequence =
                snapshot.playlist.mediaSequence,
            let segmentIndex = Int64(exactly: anchor.segmentIndex)
        else {
            return nil
        }
        let skippedCount =
            snapshot.playlist.lowLatency?.deltaUpdate?
            .skippedSegmentCount ?? 0
        guard
            let skippedCount64 = Int64(exactly: skippedCount)
        else {
            return nil
        }
        let (listedSequence, listedOverflow) =
            declaredMediaSequence.addingReportingOverflow(
                skippedCount64
            )
        let (anchorSequence, anchorOverflow) =
            listedSequence.addingReportingOverflow(segmentIndex)
        guard
            !listedOverflow,
            !anchorOverflow,
            let anchorIndex = snapshot.segments.firstIndex(
                where: {
                    $0.sequenceNumber == anchorSequence
                }
            )
        else {
            return nil
        }

        let completeDuration = snapshot.segments[anchorIndex...]
            .reduce(0) { $0 + $1.duration }
        let lastCompleteSequence =
            snapshot.segments.last?.sequenceNumber
            ?? anchorSequence
        let partialDuration = snapshot.partialSegments
            .filter {
                $0.mediaSequenceNumber > lastCompleteSequence
            }
            .reduce(0) { $0 + $1.duration }
        let duration = completeDuration + partialDuration
        guard duration.isFinite, duration >= 0 else {
            return nil
        }
        return anchor.date.addingTimeInterval(duration)
    }
}
