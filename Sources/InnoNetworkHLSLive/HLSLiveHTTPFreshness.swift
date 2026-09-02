import Foundation
import InnoNetworkHLS

/// Value-only HTTP freshness evidence for one live playlist response.
public struct HLSLiveHTTPFreshness: Equatable, Sendable {
    /// Local time when the response was converted into a live snapshot.
    public let measuredAt: Date

    /// Parsed RFC 9110 `Date` value, when valid.
    public let responseDate: Date?

    /// Parsed RFC 9110 `Last-Modified` value, when valid.
    public let lastModified: Date?

    /// Parsed nonnegative `Age` delta-seconds, when valid.
    public let reportedAge: TimeInterval?

    /// Estimated age of the delivered HTTP response in seconds.
    public let estimatedResponseAge: TimeInterval?

    /// Estimated age of the playlist representation in seconds.
    public let estimatedPlaylistAge: TimeInterval?

    init?(
        response: HLSHTTPResponseFreshness,
        measuredAt: Date
    ) {
        guard
            response.responseDate != nil
                || response.lastModified != nil
                || response.reportedAge != nil,
            measuredAt.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }
        let estimatedResponseAge = Self.responseAge(
            response,
            measuredAt: measuredAt
        )
        self.measuredAt = measuredAt
        self.responseDate = response.responseDate
        self.lastModified = response.lastModified
        self.reportedAge = response.reportedAge
        self.estimatedResponseAge = estimatedResponseAge
        self.estimatedPlaylistAge = Self.playlistAge(
            response,
            measuredAt: measuredAt,
            responseAge: estimatedResponseAge
        )
    }

    private static func responseAge(
        _ response: HLSHTTPResponseFreshness,
        measuredAt: Date
    ) -> TimeInterval? {
        let apparentAge = response.responseDate.flatMap { date in
            nonnegativeInterval(measuredAt.timeIntervalSince(date))
        }
        switch (response.reportedAge, apparentAge) {
        case (.none, .none):
            return nil
        case (.some(let age), .none), (.none, .some(let age)):
            return age
        case (.some(let reported), .some(let apparent)):
            return max(reported, apparent)
        }
    }

    private static func playlistAge(
        _ response: HLSHTTPResponseFreshness,
        measuredAt: Date,
        responseAge: TimeInterval?
    ) -> TimeInterval? {
        guard let lastModified = response.lastModified else {
            return responseAge
        }
        if let responseDate = response.responseDate {
            guard
                let ageAtOrigin = nonnegativeInterval(
                    responseDate.timeIntervalSince(lastModified)
                )
            else {
                return responseAge
            }
            guard let responseAge else {
                return ageAtOrigin
            }
            return nonnegativeInterval(ageAtOrigin + responseAge)
        }
        return nonnegativeInterval(
            measuredAt.timeIntervalSince(lastModified)
        ) ?? responseAge
    }

    private static func nonnegativeInterval(
        _ value: TimeInterval
    ) -> TimeInterval? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }
}
