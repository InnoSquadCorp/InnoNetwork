import Foundation
import InnoNetwork

/// Groups storage limits for an offline HLS package.
///
/// Offline packages are committed atomically as a complete directory. Durable
/// partial state remains private to the downloader.
public struct HLSOfflinePackageStoragePack: Sendable {
    private let maximumMediaResourceBytes: Int
    private let maximumTotalDownloadBytes: Int64
    private let diskCapacityPolicy: HLSDiskCapacityPolicy
    private let resumePolicy: HLSResumePolicy

    /// Creates an offline package storage pack.
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

    func apply(
        to builder: inout HLSOfflinePackageConfiguration.Builder
    ) {
        builder.maximumMediaResourceBytes = max(
            1,
            maximumMediaResourceBytes
        )
        builder.maximumTotalDownloadBytes = max(
            1,
            maximumTotalDownloadBytes
        )
        builder.diskCapacityPolicy = diskCapacityPolicy
        builder.resumePolicy = resumePolicy
    }
}

/// Configures bounded multi-rendition HLS offline packages.
public struct HLSOfflinePackageConfiguration: Sendable {
    let maximumMediaResourceBytes: Int
    let maximumTotalDownloadBytes: Int64
    let diskCapacityPolicy: HLSDiskCapacityPolicy
    let resumePolicy: HLSResumePolicy
    let maximumConcurrentResourceTransfers: Int
    let retryPolicy: (any RetryPolicy)?
    let variantSelectionPolicy: HLSVariantSelectionPolicy
    let renditionPack: HLSOfflineRenditionPack
    let contentSteering: HLSContentSteeringSettings
    let sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy

    struct Builder {
        var maximumMediaResourceBytes = 128 * 1_024 * 1_024
        var maximumTotalDownloadBytes: Int64 =
            8 * 1_024 * 1_024 * 1_024
        var diskCapacityPolicy: HLSDiskCapacityPolicy = .required(
            minimumAvailableCapacity: 512 * 1_024 * 1_024
        )
        var resumePolicy: HLSResumePolicy = .automatic
        var maximumConcurrentResourceTransfers = 3
        var retryPolicy: (any RetryPolicy)? =
            ExponentialBackoffRetryPolicy()
        var variantSelectionPolicy: HLSVariantSelectionPolicy =
            .highestQuality
        var renditionPack = HLSOfflineRenditionPack()
        var contentSteering = HLSContentSteeringPack().resolvedSettings
        var sessionKeyPreloadPolicy: HLSSessionKeyPreloadPolicy = .disabled
    }

    private init(builder: Builder) {
        self.maximumMediaResourceBytes =
            builder.maximumMediaResourceBytes
        self.maximumTotalDownloadBytes =
            builder.maximumTotalDownloadBytes
        self.diskCapacityPolicy = builder.diskCapacityPolicy
        self.resumePolicy = builder.resumePolicy
        self.maximumConcurrentResourceTransfers =
            builder.maximumConcurrentResourceTransfers
        self.retryPolicy = builder.retryPolicy
        self.variantSelectionPolicy =
            builder.variantSelectionPolicy
        self.renditionPack = builder.renditionPack
        self.contentSteering = builder.contentSteering
        self.sessionKeyPreloadPolicy = builder.sessionKeyPreloadPolicy
    }

    /// Returns conservative package defaults.
    ///
    /// The defaults retain one external audio rendition, omit video,
    /// subtitles, and I-frame trick-play, limit resource concurrency to three,
    /// and apply the same byte and disk capacity bounds as
    /// ``HLSDownloadConfiguration/safeDefaults()``.
    public static func safeDefaults()
        -> HLSOfflinePackageConfiguration
    {
        advanced()
    }

    /// Returns an explicitly tuned offline-package configuration.
    public static func advanced(
        storage: HLSOfflinePackageStoragePack =
            HLSOfflinePackageStoragePack(),
        variantSelectionPolicy: HLSVariantSelectionPolicy =
            .highestQuality,
        renditions: HLSOfflineRenditionPack =
            HLSOfflineRenditionPack(),
        contentSteering: HLSContentSteeringPack =
            HLSContentSteeringPack(),
        transfer: HLSTransferPack = HLSTransferPack()
    ) -> HLSOfflinePackageConfiguration {
        var builder = Builder()
        storage.apply(to: &builder)
        let transferSettings = transfer.resolvedSettings()
        builder.maximumConcurrentResourceTransfers =
            transferSettings.maximumConcurrentResourceTransfers
        builder.retryPolicy = transferSettings.retryPolicy
        builder.sessionKeyPreloadPolicy =
            transferSettings.sessionKeyPreloadPolicy
        builder.variantSelectionPolicy = variantSelectionPolicy
        builder.renditionPack = renditions
        builder.contentSteering = contentSteering.resolvedSettings
        return HLSOfflinePackageConfiguration(builder: builder)
    }
}
