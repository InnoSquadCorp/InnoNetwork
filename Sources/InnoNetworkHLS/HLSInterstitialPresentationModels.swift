import Foundation

/// How an interstitial is represented on an integrated timeline.
public enum HLSInterstitialTimelineOccupancy: Equatable, Sendable {
    /// The interstitial appears at one point on the primary timeline.
    case point

    /// The interstitial occupies a range on the integrated timeline.
    case range
}

/// Whether an interstitial is visually distinct from primary content.
public enum HLSInterstitialTimelineStyle: Equatable, Sendable {
    /// The timeline should distinguish the interstitial from primary content.
    case highlight

    /// The timeline should present the interstitial like primary content.
    case primary
}

/// A user-navigation restriction declared by an interstitial.
public enum HLSInterstitialNavigationRestriction: Equatable, Hashable,
    Sendable
{
    /// Prevent seeking or scanning forward during interstitial playback.
    case skip

    /// Prevent jumping across the interstitial from earlier primary content.
    case jump
}

/// Server-authored presentation metadata for an interstitial skip control.
public struct HLSInterstitialSkipControl: Equatable, Sendable {
    /// Whole seconds to play before presenting the control.
    ///
    /// A missing offset does not make the interstitial eligible to skip.
    public let offset: UInt64?

    /// Whole seconds for which the control remains visible.
    ///
    /// A missing duration means the control remains visible for the rest of
    /// the interstitial after it appears.
    public let duration: UInt64?

    /// An application localization key for the control label.
    public let labelID: String?

    /// Creates skip-control presentation metadata.
    public init(
        offset: UInt64? = nil,
        duration: UInt64? = nil,
        labelID: String? = nil
    ) {
        self.offset = offset
        self.duration = duration
        self.labelID = labelID
    }

    func applying(
        _ override: HLSInterstitialSkipControl?
    ) -> HLSInterstitialSkipControl {
        guard let override else {
            return self
        }
        return HLSInterstitialSkipControl(
            offset: override.offset ?? offset,
            duration: override.duration ?? duration,
            labelID: override.labelID ?? labelID
        )
    }
}
