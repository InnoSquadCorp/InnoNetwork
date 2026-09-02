import Foundation
import InnoNetwork

/// Determines how destination-volume capacity is validated before an HLS
/// download starts.
public enum HLSDiskCapacityPolicy: Equatable, Sendable {
    /// Requires the capacity lookup to succeed and the reported capacity to
    /// meet `minimumAvailableCapacity`.
    case required(minimumAvailableCapacity: Int64)

    /// Enforces `minimumAvailableCapacity` when the volume reports capacity,
    /// but allows the download to continue when capacity is unavailable.
    case bestEffort(minimumAvailableCapacity: Int64)

    /// Skips destination-volume capacity lookup.
    case disabled

    var normalizedMinimumAvailableCapacity: Int64? {
        switch self {
        case .required(let minimum), .bestEffort(let minimum):
            return max(0, minimum)
        case .disabled:
            return nil
        }
    }

    var requiresCapacityValue: Bool {
        if case .required = self {
            return true
        }
        return false
    }
}

/// Determines whether an interrupted VOD download resumes from completed
/// media-resource boundaries.
public enum HLSResumePolicy: Equatable, Sendable {
    /// Removes partial output when the operation terminates.
    case disabled

    /// Persists a destination-scoped checkpoint and reuses it when the source
    /// still resolves to the same ordered resource plan.
    case automatic
}

/// Groups per-resource, whole-download, and destination-volume safety limits.
///
/// Stored values are intentionally opaque. This type is an immutable command
/// consumed by ``HLSDownloadConfiguration`` rather than a second mutable
/// configuration model.
public struct HLSStoragePack: Sendable {
    private let maximumMediaResourceBytes: Int
    private let maximumTotalDownloadBytes: Int64
    private let diskCapacityPolicy: HLSDiskCapacityPolicy
    private let resumePolicy: HLSResumePolicy

    public init(
        maximumMediaResourceBytes: Int = 128 * 1_024 * 1_024,
        maximumTotalDownloadBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        diskCapacityPolicy: HLSDiskCapacityPolicy = .required(
            minimumAvailableCapacity: 512 * 1_024 * 1_024
        ),
        resumePolicy: HLSResumePolicy = .automatic
    ) {
        self.maximumMediaResourceBytes = maximumMediaResourceBytes
        self.maximumTotalDownloadBytes = maximumTotalDownloadBytes
        self.diskCapacityPolicy = diskCapacityPolicy
        self.resumePolicy = resumePolicy
    }

    func apply(to builder: inout HLSDownloadConfiguration.Builder) {
        builder.maximumMediaResourceBytes = max(1, maximumMediaResourceBytes)
        builder.maximumTotalDownloadBytes = max(1, maximumTotalDownloadBytes)
        builder.diskCapacityPolicy = diskCapacityPolicy
        builder.resumePolicy = resumePolicy
    }
}

/// Groups bounded media-resource concurrency, retry behavior, and optional
/// session-key preparation.
public struct HLSTransferPack: Sendable {
    private let maximumConcurrentResourceTransfers: Int
    private let retryPolicy: (any RetryPolicy)?
    private let sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy

    public init(
        maximumConcurrentResourceTransfers: Int = 3,
        retryPolicy: (any RetryPolicy)? = ExponentialBackoffRetryPolicy(),
        sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy = .disabled
    ) {
        self.maximumConcurrentResourceTransfers =
            maximumConcurrentResourceTransfers
        self.retryPolicy = retryPolicy
        self.sessionKeyPreloadPolicy = sessionKeyPreloadPolicy
    }

    func apply(to builder: inout HLSDownloadConfiguration.Builder) {
        let settings = resolvedSettings()
        builder.maximumConcurrentResourceTransfers =
            settings.maximumConcurrentResourceTransfers
        builder.retryPolicy = settings.retryPolicy
        builder.sessionKeyPreloadPolicy = settings.sessionKeyPreloadPolicy
    }

    func resolvedSettings() -> HLSResolvedTransferSettings {
        HLSResolvedTransferSettings(
            maximumConcurrentResourceTransfers: min(
                max(1, maximumConcurrentResourceTransfers),
                8
            ),
            retryPolicy: retryPolicy,
            sessionKeyPreloadPolicy: sessionKeyPreloadPolicy
        )
    }
}

struct HLSResolvedTransferSettings: Sendable {
    let maximumConcurrentResourceTransfers: Int
    let retryPolicy: (any RetryPolicy)?
    let sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy
}

/// Configures bounded HLS VOD transfer and assembly behavior.
///
/// Start with ``safeDefaults()``. Use
/// ``advanced(storage:variantSelectionPolicy:transfer:)`` only when the
/// application owns the storage, quality, concurrency, or retry trade-offs.
public struct HLSDownloadConfiguration: Sendable {
    let maximumMediaResourceBytes: Int
    let maximumTotalDownloadBytes: Int64
    let diskCapacityPolicy: HLSDiskCapacityPolicy
    let maximumConcurrentResourceTransfers: Int
    let retryPolicy: (any RetryPolicy)?
    let variantSelectionPolicy: HLSVariantSelectionPolicy
    let resumePolicy: HLSResumePolicy
    let contentSteering: HLSContentSteeringSettings
    let sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy

    struct Builder {
        var maximumMediaResourceBytes = 128 * 1_024 * 1_024
        var maximumTotalDownloadBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
        var diskCapacityPolicy: HLSDiskCapacityPolicy = .required(
            minimumAvailableCapacity: 512 * 1_024 * 1_024
        )
        var maximumConcurrentResourceTransfers = 3
        var retryPolicy: (any RetryPolicy)? = ExponentialBackoffRetryPolicy()
        var variantSelectionPolicy: HLSVariantSelectionPolicy = .highestQuality
        var resumePolicy: HLSResumePolicy = .automatic
        var contentSteering = HLSContentSteeringPack().resolvedSettings
        var sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy = .disabled
    }

    private init(builder: Builder) {
        self.maximumMediaResourceBytes = builder.maximumMediaResourceBytes
        self.maximumTotalDownloadBytes = builder.maximumTotalDownloadBytes
        self.diskCapacityPolicy = builder.diskCapacityPolicy
        self.maximumConcurrentResourceTransfers =
            builder.maximumConcurrentResourceTransfers
        self.retryPolicy = builder.retryPolicy
        self.variantSelectionPolicy = builder.variantSelectionPolicy
        self.resumePolicy = builder.resumePolicy
        self.contentSteering = builder.contentSteering
        self.sessionKeyPreloadPolicy = builder.sessionKeyPreloadPolicy
    }

    /// Returns the conservative configuration used by ``HLSDownloader``.
    ///
    /// The default limits each media resource to 128 MiB, the assembled output
    /// to 8 GiB, requires 512 MiB of currently available disk capacity,
    /// resumes from completed media-resource boundaries, prefetches at most
    /// three resources, leaves session-key preloading disabled, and selects
    /// the highest-quality supported variant.
    /// Transient GET failures receive up to three exponential-backoff retries
    /// through InnoNetwork's core ``RetryPolicy``.
    public static func safeDefaults() -> HLSDownloadConfiguration {
        advanced()
    }

    /// Returns an explicitly tuned HLS download configuration.
    ///
    /// Invalid storage and transfer values are normalized to safe runtime
    /// bounds. Byte limits are at least one, disk thresholds are non-negative,
    /// and concurrency is clamped to `1...8`. Pass `nil` to
    /// ``HLSTransferPack/init(maximumConcurrentResourceTransfers:retryPolicy:sessionKeyPreloadPolicy:)``
    /// to disable automatic retries.
    public static func advanced(
        storage: HLSStoragePack = HLSStoragePack(),
        variantSelectionPolicy: HLSVariantSelectionPolicy = .highestQuality,
        contentSteering: HLSContentSteeringPack = HLSContentSteeringPack(),
        transfer: HLSTransferPack = HLSTransferPack()
    ) -> HLSDownloadConfiguration {
        var builder = Builder()
        storage.apply(to: &builder)
        transfer.apply(to: &builder)
        builder.variantSelectionPolicy = variantSelectionPolicy
        builder.contentSteering = contentSteering.resolvedSettings
        return HLSDownloadConfiguration(builder: builder)
    }
}
