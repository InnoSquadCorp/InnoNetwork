import Foundation
import InnoNetworkHLS

/// Value-redacted interstitial packaging counters for live DVR.
public struct HLSLiveDVRInterstitialStatistics: Equatable, Sendable {
    /// Interstitial events currently retained by the recording window.
    public let retainedEventCount: Int

    /// Ordered interstitial assets currently retained across all events.
    public let retainedAssetCount: Int

    /// Playlist, metadata, manifest, and media bytes retained for events.
    public let retainedByteCount: Int64

    /// Events omitted under the configured failure policy.
    public let omittedEventCount: Int

    init(
        retainedEventCount: Int = 0,
        retainedAssetCount: Int = 0,
        retainedByteCount: Int64 = 0,
        omittedEventCount: Int = 0
    ) {
        self.retainedEventCount = retainedEventCount
        self.retainedAssetCount = retainedAssetCount
        self.retainedByteCount = retainedByteCount
        self.omittedEventCount = omittedEventCount
    }
}

struct HLSLiveDVRStoredInterstitial: Equatable, Sendable {
    let id: String
    let sourceIdentity: String
    let eventDirectoryPath: String
    let dateRange: HLSDateRange
    let assetCount: Int
    let files: [HLSLiveDVRCheckpoint.FileRecord]

    var byteCount: Int64 {
        files.reduce(into: 0) { result, file in
            result += file.byteCount
        }
    }

    var playlistCount: Int {
        files.count { file in
            file.relativePath.lowercased().hasSuffix(".m3u8")
        }
    }
}

struct HLSLiveDVROmittedInterstitial: Equatable, Sendable {
    let id: String
    let sourceIdentity: String
}

struct HLSLiveDVRResolvedDateRangeSchedule: Equatable, Sendable {
    let id: String
    let sourceIdentity: String
    let dateRanges: [HLSDateRange]
}

extension HLSLiveDVRRecordingState {
    func resolvedDateRanges(
        forScheduleID id: String,
        sourceIdentity: String
    ) throws -> [HLSDateRange]? {
        guard
            let schedule = resolvedDateRangeSchedules.first(where: {
                $0.id == id
            })
        else {
            return nil
        }
        guard schedule.sourceIdentity == sourceIdentity else {
            throw HLSLiveDVRError.interstitialPackagingFailed
        }
        return schedule.dateRanges
    }

    mutating func retainResolvedDateRangeSchedule(
        id: String,
        sourceIdentity: String,
        dateRanges: [HLSDateRange]
    ) throws {
        guard !dateRanges.isEmpty,
            !resolvedDateRangeSchedules.contains(where: { $0.id == id }),
            !resolvedDateRangeSchedules.contains(where: { schedule in
                schedule.dateRanges.contains(where: { $0.id == id })
            }),
            !self.dateRanges.contains(where: { $0.id == id })
        else {
            throw HLSLiveDVRError.interstitialPackagingFailed
        }
        let retainedInterstitialIDs = Set(interstitials.map(\.id))
        let omittedInterstitialIDs = Set(omittedInterstitials.map(\.id))
        var scheduledIDs = Set(
            resolvedDateRangeSchedules.flatMap { schedule in
                schedule.dateRanges.map(\.id)
            }
        )
        for dateRange in dateRanges {
            guard scheduledIDs.insert(dateRange.id).inserted,
                !self.dateRanges.contains(where: { existing in
                    guard existing.id == dateRange.id else {
                        return false
                    }
                    return existing != dateRange
                        && !retainedInterstitialIDs.contains(existing.id)
                        && !omittedInterstitialIDs.contains(existing.id)
                })
            else {
                throw HLSLiveDVRError.interstitialPackagingFailed
            }
        }
        var observedEventIDs = scheduledIDs
        observedEventIDs.formUnion(interstitials.map(\.id))
        observedEventIDs.formUnion(omittedInterstitials.map(\.id))
        guard
            observedEventIDs.count
                <= configuration.interstitials.maximumEventCount,
            resolvedDateRangeSchedules.count
                < configuration.interstitials.maximumEventCount
        else {
            throw HLSLiveDVRError.interstitialEventLimitExceeded(
                limit: configuration.interstitials.maximumEventCount
            )
        }
        resolvedDateRangeSchedules.append(
            HLSLiveDVRResolvedDateRangeSchedule(
                id: id,
                sourceIdentity: sourceIdentity,
                dateRanges: dateRanges
            )
        )
    }

    mutating func updateObservedDateRangeScheduleIDs(
        _ ids: Set<String>
    ) {
        observedDateRangeScheduleIDs = ids
    }

    mutating func retainInterstitial(
        _ interstitial: HLSLiveDVRStoredInterstitial
    ) throws {
        let statistics = interstitialStatistics
        let (nextInterstitialBytes, interstitialOverflow) =
            statistics.retainedByteCount.addingReportingOverflow(
                interstitial.byteCount
            )
        guard !interstitialOverflow,
            nextInterstitialBytes
                <= configuration.interstitials.maximumTotalBytes
        else {
            throw HLSLiveDVRError.interstitialStorageLimitReached
        }
        try addMediaBytes(interstitial.byteCount)
        interstitials.append(interstitial)
    }

    mutating func updateInterstitialDateRange(
        id: String,
        dateRange: HLSDateRange
    ) throws {
        guard
            let index = interstitials.firstIndex(where: {
                $0.id == id
            })
        else {
            throw HLSLiveDVRError.interstitialPackagingFailed
        }
        let stored = interstitials[index]
        interstitials[index] = HLSLiveDVRStoredInterstitial(
            id: stored.id,
            sourceIdentity: stored.sourceIdentity,
            eventDirectoryPath: stored.eventDirectoryPath,
            dateRange: dateRange,
            assetCount: stored.assetCount,
            files: stored.files
        )
    }

    mutating func omitInterstitial(
        id: String,
        sourceIdentity: String
    ) {
        guard !omittedInterstitials.contains(where: { $0.id == id }) else {
            return
        }
        omittedInterstitials.append(
            HLSLiveDVROmittedInterstitial(
                id: id,
                sourceIdentity: sourceIdentity
            )
        )
    }

    mutating func discardInterstitialDateRange(id: String) {
        dateRanges.removeAll { $0.id == id }
    }

    mutating func pruneExpiredInterstitials() throws {
        guard configuration.limits.retentionPolicy == .rollingWindow,
            let retainedStart = segments.first?.programDateTime
        else {
            return
        }
        let expired = interstitials.filter { interstitial in
            guard let end = Self.endDate(of: interstitial.dateRange) else {
                return false
            }
            return end <= retainedStart
        }
        let expiredIDs = Set(expired.map(\.id))
        for interstitial in expired {
            guard mediaByteCount >= interstitial.byteCount else {
                throw HLSLiveDVRError.storageFailed
            }
            mediaByteCount -= interstitial.byteCount
            pendingEvictionFilePaths.insert(
                interstitial.eventDirectoryPath
            )
            retentionStatistics = try retentionStatistics.adding(
                mediaByteCount: interstitial.byteCount
            )
        }
        if !expiredIDs.isEmpty {
            interstitials.removeAll { expiredIDs.contains($0.id) }
            dateRanges.removeAll { expiredIDs.contains($0.id) }
        }
        resolvedDateRangeSchedules.removeAll { schedule in
            guard
                !observedDateRangeScheduleIDs.contains(schedule.id)
            else {
                return false
            }
            return schedule.dateRanges.allSatisfy { dateRange in
                guard let end = Self.endDate(of: dateRange) else {
                    return false
                }
                return end <= retainedStart
            }
        }
    }

    private static func endDate(
        of dateRange: HLSDateRange
    ) -> Date? {
        dateRange.endDate
            ?? dateRange.duration.map {
                dateRange.startDate.addingTimeInterval($0)
            }
    }
}
