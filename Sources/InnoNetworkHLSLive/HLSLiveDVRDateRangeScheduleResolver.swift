import Foundation
import InnoNetworkHLS

struct HLSLiveDVRDateRangeScheduleResolver: Sendable {
    private let resolver: HLSExternalResourceResolver
    private let configuration: HLSLiveDVRConfiguration
    private let preloadCoordinator: HLSLiveDVRDateRangePreloadCoordinator

    init(
        resolver: HLSExternalResourceResolver,
        configuration: HLSLiveDVRConfiguration
    ) {
        self.resolver = resolver
        self.configuration = configuration
        self.preloadCoordinator = HLSLiveDVRDateRangePreloadCoordinator(
            resolver: resolver
        )
    }

    func resolve(
        from snapshot: HLSLivePlaylistSnapshot,
        state: inout HLSLiveDVRRecordingState
    ) async throws -> [HLSDateRange] {
        let scheduleIDs = Set(
            snapshot.dateRanges.compactMap { dateRange in
                Self.isDateRangeSchedule(dateRange)
                    ? dateRange.id : nil
            }
        )
        state.updateObservedDateRangeScheduleIDs(scheduleIDs)
        guard configuration.interstitials.policy == .package else {
            return snapshot.dateRanges
        }
        await preloadCoordinator.update(
            from: snapshot,
            excludingTargetIDs: Set(
                state.resolvedDateRangeSchedules.map(\.id)
            )
        )
        guard
            !scheduleIDs.isEmpty
                || !state.resolvedDateRangeSchedules.isEmpty
        else {
            return snapshot.dateRanges.filter {
                !Self.isDateRangePreload($0)
            }
        }

        let playlistIDs = Set(snapshot.dateRanges.map(\.id))
        var occupiedIDs = playlistIDs
        occupiedIDs.formUnion(
            state.resolvedDateRangeSchedules.flatMap { schedule in
                schedule.dateRanges.map(\.id)
            }
        )
        var resolved: [HLSDateRange] = []
        for dateRange in snapshot.dateRanges {
            if Self.isDateRangePreload(dateRange) {
                continue
            }
            guard Self.isDateRangeSchedule(dateRange) else {
                resolved.append(dateRange)
                continue
            }
            let sourceIdentity = try Self.sourceIdentity(dateRange)
            let scheduledDateRanges: [HLSDateRange]
            if let cached = try state.resolvedDateRanges(
                forScheduleID: dateRange.id,
                sourceIdentity: sourceIdentity
            ) {
                scheduledDateRanges = cached
                await preloadCoordinator.discard(for: dateRange)
            } else {
                let preload = try await preloadCoordinator.consume(
                    for: dateRange
                )
                let schedule = try await resolveSchedule(
                    dateRange,
                    preload: preload,
                    occupiedDateRangeIDs: occupiedIDs
                )
                scheduledDateRanges = Self.flatten(schedule)
                try state.validateDateRanges(
                    scheduledDateRanges,
                    isPrimary: true
                )
                try state.retainResolvedDateRangeSchedule(
                    id: dateRange.id,
                    sourceIdentity: sourceIdentity,
                    dateRanges: scheduledDateRanges
                )
            }
            let unmaterializedDateRanges = scheduledDateRanges.filter {
                !playlistIDs.contains($0.id)
            }
            occupiedIDs.formUnion(unmaterializedDateRanges.map(\.id))
            resolved.append(contentsOf: unmaterializedDateRanges)
        }
        for schedule in state.resolvedDateRangeSchedules
        where !scheduleIDs.contains(schedule.id) {
            resolved.append(
                contentsOf: schedule.dateRanges.filter {
                    !playlistIDs.contains($0.id)
                }
            )
        }
        return resolved
    }

    func cancelPreloads() async {
        await preloadCoordinator.cancelAll()
    }

    private func resolveSchedule(
        _ dateRange: HLSDateRange,
        preload: HLSLiveDVRDateRangePreload?,
        occupiedDateRangeIDs: Set<String>
    ) async throws -> HLSDateRangeSchedule {
        let matchingResource: HLSPreloadedDateRangeResource? =
            preload?.resource.flatMap { resource in
                guard resource.sourceURL == dateRange.externalResource?.url,
                    resource.targetID == dateRange.id,
                    resource.targetClass == dateRange.className
                else {
                    return nil
                }
                return resource
            }
        if let matchingResource {
            do {
                return try await resolver.resolveDateRangeSchedule(
                    dateRange,
                    preloadedResource: matchingResource,
                    startOffset: preload?.startOffset,
                    occupiedDateRangeIDs: occupiedDateRangeIDs
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A stale preload is only an optimization failure. Retry the
                // authoritative schedule URL before failing the recording.
            }
        }
        do {
            return try await resolver.resolveDateRangeSchedule(
                dateRange,
                startOffset: preload?.startOffset,
                occupiedDateRangeIDs: occupiedDateRangeIDs
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HLSLiveDVRError.interstitialPackagingFailed
        }
    }

    private static func flatten(
        _ schedule: HLSDateRangeSchedule
    ) -> [HLSDateRange] {
        schedule.entries.flatMap { entry in
            if let nested = entry.nestedSchedule {
                return flatten(nested)
            }
            return [normalized(entry.dateRange)]
        }
    }

    private static func normalized(
        _ dateRange: HLSDateRange
    ) -> HLSDateRange {
        HLSDateRange(
            id: dateRange.id,
            className: dateRange.className,
            startDate: dateRange.startDate,
            endDate: dateRange.endDate,
            duration: dateRange.duration,
            plannedDuration: dateRange.plannedDuration,
            cues: dateRange.cues,
            endsOnNext: dateRange.endsOnNext,
            interstitial: dateRange.interstitial,
            externalResource: dateRange.externalResource,
            preload: dateRange.preload,
            extensionAttributeNames:
                dateRange.extensionAttributeNames.filter {
                    $0 != "X-SCHEDULE-OFFSET"
                }
        )
    }

    private static func isDateRangeSchedule(
        _ dateRange: HLSDateRange
    ) -> Bool {
        dateRange.className == dateRangeScheduleClass
            && dateRange.externalResource != nil
    }

    private static func isDateRangePreload(
        _ dateRange: HLSDateRange
    ) -> Bool {
        dateRange.className == dateRangePreloadClass
            && dateRange.preload != nil
    }

    private static func sourceIdentity(
        _ dateRange: HLSDateRange
    ) throws -> String {
        guard let url = dateRange.externalResource?.url else {
            throw HLSLiveDVRError.interstitialPackagingFailed
        }
        let fields = [
            dateRange.id,
            dateRange.className ?? "",
            HLSLiveDVRRecoveryIdentity.sourceURLSHA256(url),
            fingerprint(dateRange.startDate.timeIntervalSinceReferenceDate),
            fingerprint(
                dateRange.endDate?.timeIntervalSinceReferenceDate
            ),
            fingerprint(dateRange.duration),
            fingerprint(dateRange.plannedDuration),
            dateRange.cues.map(cueIdentity).joined(separator: ","),
            dateRange.endsOnNext ? "1" : "0",
        ]
        return "schedule:"
            + HLSContentFingerprint.sha256(
                fields.joined(separator: "\u{1f}")
            )
    }

    private static func fingerprint(
        _ value: TimeInterval?
    ) -> String {
        value.map { String($0.bitPattern) } ?? "-"
    }

    private static func cueIdentity(_ cue: HLSDateRangeCue) -> String {
        switch cue {
        case .pre:
            "pre"
        case .post:
            "post"
        case .once:
            "once"
        }
    }

    private static let dateRangeScheduleClass =
        "com.apple.hls.daterange-schedule"

    private static let dateRangePreloadClass =
        "com.apple.hls.preload"
}
