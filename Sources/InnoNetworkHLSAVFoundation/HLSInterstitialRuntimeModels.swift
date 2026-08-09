import Foundation

/// Value-redacted metadata for one scheduled AVFoundation interstitial.
///
/// Asset URLs, user-defined attributes, asset-list responses, and underlying
/// errors are intentionally excluded.
public struct HLSInterstitialEventSnapshot: Equatable, Sendable {
    /// The event identifier used to correlate lifecycle updates.
    public let identifier: String

    /// The primary media time in seconds, when numeric and finite.
    public let scheduledTime: TimeInterval?

    /// The primary wall-clock date, when the event is date scheduled.
    public let scheduledDate: Date?

    /// The number of interstitial template items.
    public let templateItemCount: Int

    /// The primary-content resumption offset, when numeric and finite.
    public let resumptionOffset: TimeInterval?

    /// The maximum interstitial playout duration, when numeric and finite.
    public let playoutLimit: TimeInterval?
}

/// The availability of an interstitial event's remote asset list.
public enum HLSInterstitialAssetListStatus: Equatable, Sendable {
    /// The asset list was loaded.
    case available

    /// A previously loaded asset list was cleared.
    case cleared

    /// The asset list request failed.
    case unavailable

    /// A future AVFoundation status is not modeled by this bridge.
    case other
}

/// Whether the current interstitial can be skipped by system UI.
public enum HLSInterstitialSkippableState: Equatable, Sendable {
    /// The event is not skippable.
    case notSkippable

    /// The event will become skippable later.
    case notYetEligible

    /// The event is currently skippable.
    case eligible

    /// The event's skip window has ended.
    case noLongerEligible

    /// A future AVFoundation state is not modeled by this bridge.
    case other
}

/// A bounded, value-redacted AVFoundation interstitial lifecycle update.
public enum HLSInterstitialRuntimeEvent: Equatable, Sendable {
    /// The intrinsic or application-authored schedule changed.
    case scheduleChanged([HLSInterstitialEventSnapshot])

    /// Playback entered or exited an interstitial event.
    case currentEventChanged(HLSInterstitialEventSnapshot?)

    /// An event's asset-list request state changed.
    case assetListStatusChanged(
        HLSInterstitialEventSnapshot,
        status: HLSInterstitialAssetListStatus,
        hadError: Bool
    )

    /// The current event's system skip eligibility changed.
    case skippableStateChanged(
        HLSInterstitialEventSnapshot,
        state: HLSInterstitialSkippableState
    )

    /// The user invoked the system skip control.
    case skipped(HLSInterstitialEventSnapshot)

    /// A loaded event was removed before playback.
    case unscheduled(
        HLSInterstitialEventSnapshot,
        hadError: Bool
    )

    /// An event finished or was canceled after playback began.
    case finished(
        HLSInterstitialEventSnapshot,
        playoutDuration: TimeInterval?,
        didPlayEntireEvent: Bool
    )

    /// A Date Range schedule request completed.
    ///
    /// The identifier, JSON response, and underlying error are excluded.
    case scheduleRequestCompleted(succeeded: Bool)
}
