import Foundation
import InnoNetworkHLS

struct HLSLiveDVRDateRangePreload: Sendable {
    let startOffset: TimeInterval?
    let resource: HLSPreloadedDateRangeResource?
}

actor HLSLiveDVRDateRangePreloadCoordinator {
    private struct Target: Equatable, Sendable {
        let id: String
        let targetID: String
        let targetClass: String
        let sourceIdentity: String
        let expirationDate: Date?
        let startOffset: TimeInterval?
    }

    private enum Outcome: Sendable {
        case loaded(HLSPreloadedDateRangeResource)
        case failed
        case cancelled
    }

    private struct Entry: Sendable {
        let target: Target
        let task: Task<Outcome, Never>
    }

    private let resolver: HLSExternalResourceResolver
    private var entries: [Entry] = []
    private var retiredTasks: [UUID: Task<Outcome, Never>] = [:]
    private var isClosed = false

    init(resolver: HLSExternalResourceResolver) {
        self.resolver = resolver
    }

    func update(
        from snapshot: HLSLivePlaylistSnapshot,
        excludingTargetIDs: Set<String>
    ) {
        guard !isClosed else {
            return
        }
        let scheduleIDs = Set(
            snapshot.dateRanges.compactMap { dateRange in
                dateRange.className == Self.dateRangeScheduleClass
                    ? dateRange.id : nil
            }
        )
        pruneExpired(
            before: Self.observedEnd(in: snapshot),
            retainingTargetIDs: scheduleIDs
        )
        for dateRange in snapshot.dateRanges {
            guard let preload = dateRange.preload,
                preload.targetClass == Self.dateRangeScheduleClass,
                preload.isEligible,
                !excludingTargetIDs.contains(preload.targetID)
            else {
                continue
            }
            let expirationDate = Self.endDate(of: dateRange)
            if !scheduleIDs.contains(preload.targetID),
                let observedEnd = Self.observedEnd(in: snapshot),
                let expirationDate,
                expirationDate < observedEnd
            {
                continue
            }
            let target = Target(
                id: dateRange.id,
                targetID: preload.targetID,
                targetClass: preload.targetClass,
                sourceIdentity: Self.sourceIdentity(dateRange),
                expirationDate: expirationDate,
                startOffset: preload.durationAtJoin
            )
            if let index = entries.firstIndex(where: {
                $0.target.targetID == target.targetID
                    && $0.target.targetClass == target.targetClass
            }) {
                guard entries[index].target != target else {
                    continue
                }
                retire(entries.remove(at: index).task)
            }
            guard entries.count < Self.maximumRetainedCount else {
                continue
            }
            let resolver = resolver
            let task = Task<Outcome, Never> {
                do {
                    return .loaded(
                        try await resolver.preloadDateRangeResource(
                            dateRange
                        )
                    )
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed
                }
            }
            entries.append(Entry(target: target, task: task))
        }
    }

    func consume(
        for schedule: HLSDateRange
    ) async throws -> HLSLiveDVRDateRangePreload? {
        guard
            let index = entries.firstIndex(where: {
                $0.target.targetID == schedule.id
                    && $0.target.targetClass == schedule.className
            })
        else {
            return nil
        }
        let entry = entries.remove(at: index)
        let outcome = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            entry.task.cancel()
        }
        try Task.checkCancellation()
        switch outcome {
        case .loaded(let resource):
            return HLSLiveDVRDateRangePreload(
                startOffset: entry.target.startOffset,
                resource: resource
            )
        case .failed, .cancelled:
            return HLSLiveDVRDateRangePreload(
                startOffset: entry.target.startOffset,
                resource: nil
            )
        }
    }

    func discard(for schedule: HLSDateRange) {
        guard
            let index = entries.firstIndex(where: {
                $0.target.targetID == schedule.id
                    && $0.target.targetClass == schedule.className
            })
        else {
            return
        }
        retire(entries.remove(at: index).task)
    }

    func cancelAll() async {
        isClosed = true
        let tasks = entries.map(\.task) + retiredTasks.values
        entries.removeAll()
        retiredTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.value
        }
    }

    private func pruneExpired(
        before observedEnd: Date?,
        retainingTargetIDs: Set<String>
    ) {
        guard let observedEnd else {
            return
        }
        var retained: [Entry] = []
        for entry in entries {
            if retainingTargetIDs.contains(entry.target.targetID)
                || entry.target.expirationDate.map({
                    $0 >= observedEnd
                }) != false
            {
                retained.append(entry)
            } else {
                retire(entry.task)
            }
        }
        entries = retained
    }

    private func retire(_ task: Task<Outcome, Never>) {
        task.cancel()
        let id = UUID()
        retiredTasks[id] = task
        Task { [weak self] in
            _ = await task.value
            await self?.removeRetiredTask(id)
        }
    }

    private func removeRetiredTask(_ id: UUID) {
        retiredTasks[id] = nil
    }

    private static func sourceIdentity(
        _ dateRange: HLSDateRange
    ) -> String {
        guard let preload = dateRange.preload else {
            return ""
        }
        let fields = [
            dateRange.id,
            preload.targetID,
            preload.targetClass,
            HLSContentFingerprint.sha256(
                preload.resource.url.absoluteString
            ),
            fingerprint(dateRange.startDate.timeIntervalSinceReferenceDate),
            fingerprint(dateRange.duration),
            fingerprint(preload.durationAtJoin),
        ]
        return HLSContentFingerprint.sha256(
            fields.joined(separator: "\u{1f}")
        )
    }

    private static func observedEnd(
        in snapshot: HLSLivePlaylistSnapshot
    ) -> Date? {
        guard let segment = snapshot.segments.last,
            let startDate = segment.programDateTime
        else {
            return nil
        }
        let endDate = startDate.addingTimeInterval(segment.duration)
        return endDate.timeIntervalSinceReferenceDate.isFinite
            ? endDate : nil
    }

    private static func endDate(
        of dateRange: HLSDateRange
    ) -> Date? {
        dateRange.endDate
            ?? dateRange.duration.map {
                dateRange.startDate.addingTimeInterval($0)
            }
    }

    private static func fingerprint(
        _ value: TimeInterval?
    ) -> String {
        value.map { String($0.bitPattern) } ?? "-"
    }

    private static let maximumRetainedCount = 32
    private static let dateRangeScheduleClass =
        "com.apple.hls.daterange-schedule"
}
