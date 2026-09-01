import Foundation
import InnoNetworkHLS

/// Groups live playlist reload timing and protocol optimizations.
public struct HLSLiveReloadPack: Sendable {
    private static let maximumPollingIntervalLimit: TimeInterval = 3_600
    private static let maximumRequestTimeout: TimeInterval = 300

    private let prefersBlockingReloads: Bool
    private let allowsDeltaUpdates: Bool
    private let minimumPollingInterval: TimeInterval
    private let maximumPollingInterval: TimeInterval
    private let requestTimeout: TimeInterval

    /// Creates bounded live reload settings.
    ///
    /// Polling intervals are clamped to at least 50 milliseconds and the
    /// maximum never falls below the minimum. Request timeout is at least one
    /// second so a blocking reload can outlive ordinary playlist latency.
    public init(
        prefersBlockingReloads: Bool = true,
        allowsDeltaUpdates: Bool = true,
        minimumPollingInterval: TimeInterval = 0.5,
        maximumPollingInterval: TimeInterval = 30,
        requestTimeout: TimeInterval = 45
    ) {
        self.prefersBlockingReloads = prefersBlockingReloads
        self.allowsDeltaUpdates = allowsDeltaUpdates
        self.minimumPollingInterval = minimumPollingInterval
        self.maximumPollingInterval = maximumPollingInterval
        self.requestTimeout = requestTimeout
    }

    func resolvedSettings() -> HLSLiveReloadSettings {
        let minimum = Self.normalized(
            minimumPollingInterval,
            fallback: 0.5,
            minimum: 0.05,
            maximum: Self.maximumPollingIntervalLimit
        )
        let maximum = max(
            minimum,
            Self.normalized(
                maximumPollingInterval,
                fallback: 30,
                minimum: minimum,
                maximum: Self.maximumPollingIntervalLimit
            )
        )
        return HLSLiveReloadSettings(
            prefersBlockingReloads: prefersBlockingReloads,
            allowsDeltaUpdates: allowsDeltaUpdates,
            minimumPollingInterval: minimum,
            maximumPollingInterval: maximum,
            requestTimeout: Self.normalized(
                requestTimeout,
                fallback: 45,
                minimum: 1,
                maximum: Self.maximumRequestTimeout
            )
        )
    }

    private static func normalized(
        _ value: TimeInterval,
        fallback: TimeInterval,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else {
            return fallback
        }
        return min(maximum, max(minimum, value))
    }
}

struct HLSLiveReloadSettings: Sendable {
    let prefersBlockingReloads: Bool
    let allowsDeltaUpdates: Bool
    let minimumPollingInterval: TimeInterval
    let maximumPollingInterval: TimeInterval
    let requestTimeout: TimeInterval
}

/// Groups bounded Low-Latency HLS CDN tune-in behavior.
public struct HLSLiveCDNTuneInPack: Sendable {
    private static let maximumAdditionalRequestLimit = 8

    private let isEnabled: Bool
    private let maximumAdditionalRequestCount: Int

    /// Creates freshness-aware CDN tune-in settings.
    ///
    /// Additional playlist requests are clamped to `1...8`. Set
    /// `isEnabled` to `false` to preserve a single media-playlist request.
    public init(
        isEnabled: Bool = true,
        maximumAdditionalRequestCount: Int = 3
    ) {
        self.isEnabled = isEnabled
        self.maximumAdditionalRequestCount =
            maximumAdditionalRequestCount
    }

    func resolvedSettings() -> HLSLiveCDNTuneInSettings {
        HLSLiveCDNTuneInSettings(
            isEnabled: isEnabled,
            maximumAdditionalRequestCount: min(
                Self.maximumAdditionalRequestLimit,
                max(1, maximumAdditionalRequestCount)
            )
        )
    }
}

struct HLSLiveCDNTuneInSettings: Sendable {
    let isEnabled: Bool
    let maximumAdditionalRequestCount: Int
}

/// Configures an ``HLSLivePlaylistClient`` reload loop.
public struct HLSLiveConfiguration: Sendable {
    let reload: HLSLiveReloadSettings
    let cdnTuneIn: HLSLiveCDNTuneInSettings
    let variantSelectionPolicy: HLSVariantSelectionPolicy
    let contentSteering: HLSContentSteeringPack

    private init(
        reload: HLSLiveReloadSettings,
        cdnTuneIn: HLSLiveCDNTuneInSettings,
        variantSelectionPolicy: HLSVariantSelectionPolicy,
        contentSteering: HLSContentSteeringPack
    ) {
        self.reload = reload
        self.cdnTuneIn = cdnTuneIn
        self.variantSelectionPolicy = variantSelectionPolicy
        self.contentSteering = contentSteering
    }

    /// Returns conservative automatic blocking/delta reload behavior.
    public static func safeDefaults() -> HLSLiveConfiguration {
        advanced()
    }

    /// Returns explicitly tuned live reload behavior.
    public static func advanced(
        reload: HLSLiveReloadPack = HLSLiveReloadPack()
    ) -> HLSLiveConfiguration {
        HLSLiveConfiguration(
            reload: reload.resolvedSettings(),
            cdnTuneIn: HLSLiveCDNTuneInPack().resolvedSettings(),
            variantSelectionPolicy: .highestQuality,
            contentSteering: HLSContentSteeringPack()
        )
    }

    /// Returns explicitly tuned reload and CDN tune-in behavior.
    public static func advanced(
        reload: HLSLiveReloadPack = HLSLiveReloadPack(),
        cdnTuneIn: HLSLiveCDNTuneInPack
    ) -> HLSLiveConfiguration {
        HLSLiveConfiguration(
            reload: reload.resolvedSettings(),
            cdnTuneIn: cdnTuneIn.resolvedSettings(),
            variantSelectionPolicy: .highestQuality,
            contentSteering: HLSContentSteeringPack()
        )
    }

    /// Returns live reload behavior with explicit multivariant selection and
    /// Content Steering policy.
    public static func advanced(
        reload: HLSLiveReloadPack = HLSLiveReloadPack(),
        variantSelectionPolicy: HLSVariantSelectionPolicy,
        contentSteering: HLSContentSteeringPack =
            HLSContentSteeringPack()
    ) -> HLSLiveConfiguration {
        HLSLiveConfiguration(
            reload: reload.resolvedSettings(),
            cdnTuneIn: HLSLiveCDNTuneInPack().resolvedSettings(),
            variantSelectionPolicy: variantSelectionPolicy,
            contentSteering: contentSteering
        )
    }

    /// Returns fully tuned live reload, CDN, selection, and steering behavior.
    public static func advanced(
        reload: HLSLiveReloadPack = HLSLiveReloadPack(),
        variantSelectionPolicy: HLSVariantSelectionPolicy,
        contentSteering: HLSContentSteeringPack =
            HLSContentSteeringPack(),
        cdnTuneIn: HLSLiveCDNTuneInPack
    ) -> HLSLiveConfiguration {
        HLSLiveConfiguration(
            reload: reload.resolvedSettings(),
            cdnTuneIn: cdnTuneIn.resolvedSettings(),
            variantSelectionPolicy: variantSelectionPolicy,
            contentSteering: contentSteering
        )
    }
}
