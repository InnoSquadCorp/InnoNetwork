import Foundation
import InnoNetworkHLS

struct HLSLiveDVRDateRangeScheduleResolver: Sendable {
    private let resolver: HLSExternalResourceResolver
    private let configuration: HLSLiveDVRConfiguration

    init(
        resolver: HLSExternalResourceResolver,
        configuration: HLSLiveDVRConfiguration
    ) {
        self.resolver = resolver
        self.configuration = configuration
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
        guard
            !scheduleIDs.isEmpty
                || !state.resolvedDateRangeSchedules.isEmpty
        else {
            return snapshot.dateRanges
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
            } else {
                let schedule: HLSDateRangeSchedule
                do {
                    schedule = try await resolver.resolveDateRangeSchedule(
                        dateRange,
                        occupiedDateRangeIDs: occupiedIDs
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw HLSLiveDVRError.interstitialPackagingFailed
                }
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
        dateRange.className == "com.apple.hls.daterange-schedule"
            && dateRange.externalResource != nil
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
}
