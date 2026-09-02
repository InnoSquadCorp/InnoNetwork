#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

/// Why an application exchanges one FairPlay SPC for a CKC.
public enum HLSFairPlayLicenseRequestPurpose: Equatable, Sendable {
    /// The first streaming-key response for a content key request.
    case initial

    /// A replacement response for an expiring streaming key.
    case renewal
}

/// App-owned inputs for an initial or renewing streaming-key request.
public struct HLSFairPlayStreamingKeyAcquisition: Sendable {
    /// The FairPlay application certificate.
    public let applicationCertificate: Data

    /// The opaque content identifier used to create the SPC.
    public let contentIdentifier: Data

    /// FairPlay protocol versions supported by the application's key server.
    ///
    /// Version `1` preserves AVFoundation's compatibility behavior. Advertise
    /// version `3` only after an SDK 26 certificate and the matching KSM pass
    /// Apple's test vectors and protected-content acceptance tests.
    public let supportedProtocolVersions: [Int]

    /// Whether SPC generation randomizes FairPlay's anonymized device ID.
    ///
    /// The default preserves AVFoundation behavior. Randomized policies require
    /// version 26 or newer and must be coordinated with the application's KSM
    /// and playback business rules before use.
    public let deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy

    /// Creates acquisition inputs for one streaming-key request.
    public init(
        applicationCertificate: Data,
        contentIdentifier: Data,
        supportedProtocolVersions: [Int] = [1],
        deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy =
            .systemDefault
    ) {
        self.applicationCertificate = applicationCertificate
        self.contentIdentifier = contentIdentifier
        self.supportedProtocolVersions = supportedProtocolVersions
        self.deviceIdentifierPolicy = deviceIdentifierPolicy
    }
}

/// Hard byte limits for online FairPlay streaming-key acquisition.
public struct HLSFairPlayStreamingKeyLimitPack: Sendable {
    private static let maximumByteLimit = 16 * 1_024 * 1_024

    /// Maximum application-certificate bytes.
    public let maximumApplicationCertificateBytes: Int

    /// Maximum opaque content-identifier bytes.
    public let maximumContentIdentifierBytes: Int

    /// Maximum SPC bytes accepted before license transport.
    public let maximumSPCBytes: Int

    /// Maximum key-vendor response bytes accepted from license transport.
    public let maximumLicenseResponseBytes: Int

    /// Creates bounded online FairPlay material limits.
    ///
    /// Each value is clamped to `1...16 MiB`.
    public init(
        maximumApplicationCertificateBytes: Int =
            1 * 1_024 * 1_024,
        maximumContentIdentifierBytes: Int = 64 * 1_024,
        maximumSPCBytes: Int = 1 * 1_024 * 1_024,
        maximumLicenseResponseBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.maximumApplicationCertificateBytes = Self.normalized(
            maximumApplicationCertificateBytes
        )
        self.maximumContentIdentifierBytes = Self.normalized(
            maximumContentIdentifierBytes
        )
        self.maximumSPCBytes = Self.normalized(maximumSPCBytes)
        self.maximumLicenseResponseBytes = Self.normalized(
            maximumLicenseResponseBytes
        )
    }

    private static func normalized(_ value: Int) -> Int {
        min(maximumByteLimit, max(1, value))
    }
}

/// Configures streaming-key acquisition without owning credentials.
public struct HLSFairPlayStreamingKeyConfiguration: Sendable {
    let limits: HLSFairPlayStreamingKeyLimitPack

    private init(limits: HLSFairPlayStreamingKeyLimitPack) {
        self.limits = limits
    }

    /// Returns conservative streaming-key defaults.
    public static func safeDefaults()
        -> HLSFairPlayStreamingKeyConfiguration
    {
        advanced()
    }

    /// Returns explicitly tuned streaming-key behavior.
    public static func advanced(
        limits: HLSFairPlayStreamingKeyLimitPack =
            HLSFairPlayStreamingKeyLimitPack()
    ) -> HLSFairPlayStreamingKeyConfiguration {
        HLSFairPlayStreamingKeyConfiguration(limits: limits)
    }
}

/// A value-redacted FairPlay content-key lifecycle event.
public enum HLSFairPlayContentKeyEvent: Equatable, Sendable {
    /// A cached advisory key fulfilled the request without license transport.
    case fulfilledByAdvisoryKey(HLSFairPlayLicenseRequestPurpose)

    /// A bounded CKC was submitted to AVFoundation for validation.
    case responseSubmitted(HLSFairPlayLicenseRequestPurpose)

    /// AVFoundation confirmed that the submitted response was accepted.
    case responseAccepted(HLSFairPlayLicenseRequestPurpose)

    /// AVFoundation offered a typed reason to retry a request.
    case retryRequested(HLSFairPlayContentKeyRetryReason)

    /// A request failed with a value-redacted classification.
    case failed(HLSFairPlayContentKeyFailureReason)
}

/// Stable AVFoundation reasons for retrying a content-key request.
public enum HLSFairPlayContentKeyRetryReason: Equatable, Sendable {
    /// The prior request or response exceeded AVFoundation's time budget.
    case timedOut

    /// The prior response contained an already expired lease.
    case expiredLease

    /// The prior response contained an obsolete content key.
    case obsoleteContentKey

    /// A newer SDK supplied a reason this version does not classify.
    case unknown

    /// Maps an AVFoundation retry reason without exposing raw values.
    public init(_ reason: AVContentKeyRequest.RetryReason) {
        switch reason {
        case .timedOut:
            self = .timedOut
        case .receivedResponseWithExpiredLease:
            self = .expiredLease
        case .receivedObsoleteContentKey:
            self = .obsoleteContentKey
        default:
            self = .unknown
        }
    }
}

/// Stable, value-redacted content-key failure categories.
public enum HLSFairPlayContentKeyFailureReason: Equatable, Sendable {
    /// The request was cancelled by the caller or AVFoundation.
    case cancelled

    /// Network or content-key processing timed out.
    case timedOut

    /// The application or content was not authorized.
    case notAuthorized

    /// Protected content became unavailable or no longer playable.
    case contentUnavailable

    /// AVFoundation could not create the content-key request.
    case requestCreationFailed

    /// AVFoundation rejected the content-key response.
    case invalidResponse

    /// The error did not match a stable public classification.
    case unknown

    /// Maps an arbitrary failure without retaining its payload.
    public init(_ error: any Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSURLErrorDomain {
            switch cocoaError.code {
            case NSURLErrorCancelled:
                self = .cancelled
            case NSURLErrorTimedOut:
                self = .timedOut
            default:
                self = .unknown
            }
            return
        }
        guard cocoaError.domain == AVFoundationErrorDomain else {
            self = .unknown
            return
        }
        switch cocoaError.code {
        case AVError.Code.operationCancelled.rawValue,
            AVError.Code.contentKeyRequestCancelled.rawValue:
            self = .cancelled
        case AVError.Code.contentIsNotAuthorized.rawValue,
            AVError.Code.applicationIsNotAuthorized.rawValue:
            self = .notAuthorized
        case AVError.Code.contentIsUnavailable.rawValue,
            AVError.Code.noLongerPlayable.rawValue:
            self = .contentUnavailable
        case -11_860:
            // AVErrorCreateContentKeyRequestFailed is macOS-only, but its
            // documented code can arrive through cross-platform diagnostics.
            self = .requestCreationFailed
        case -11_889:
            // AVErrorContentKeyInvalid is newer than this package's floors.
            self = .invalidResponse
        default:
            self = .unknown
        }
    }
}

/// A value-redacted online streaming-key workflow failure.
public enum HLSFairPlayStreamingKeyError: Error, Equatable, Sendable {
    /// The application certificate is empty or exceeds its byte limit.
    case invalidApplicationCertificate

    /// The content identifier is empty or exceeds its byte limit.
    case invalidContentIdentifier

    /// The supported FairPlay protocol-version list is empty or malformed.
    case invalidProtocolVersions

    /// Device-ID randomization requires version 26 or newer.
    case deviceIdentifierRandomizationUnavailable

    /// An application-generated device-ID seed was not exactly 16 bytes.
    case invalidDeviceIdentifierSeed

    /// AVFoundation could not generate a bounded SPC.
    case spcGenerationFailed

    /// Application-owned license transport failed.
    case licenseExchangeFailed

    /// License transport returned empty or oversized response data.
    case invalidLicenseResponse
}

extension HLSFairPlayStreamingKeyError: LocalizedError {
    public var errorDescription: String? {
        streamingKeyLocalized(
            "HLSFairPlayStreamingKeyError.\(localizationKey)"
        )
    }

    public var recoverySuggestion: String? {
        streamingKeyLocalized(
            "HLSFairPlayStreamingKeyError.recovery."
                + recoveryLocalizationKey
        )
    }

    private var localizationKey: String {
        switch self {
        case .invalidApplicationCertificate:
            return "invalidApplicationCertificate"
        case .invalidContentIdentifier:
            return "invalidContentIdentifier"
        case .invalidProtocolVersions:
            return "invalidProtocolVersions"
        case .deviceIdentifierRandomizationUnavailable:
            return "deviceIdentifierRandomizationUnavailable"
        case .invalidDeviceIdentifierSeed:
            return "invalidDeviceIdentifierSeed"
        case .spcGenerationFailed:
            return "spcGenerationFailed"
        case .licenseExchangeFailed:
            return "licenseExchangeFailed"
        case .invalidLicenseResponse:
            return "invalidLicenseResponse"
        }
    }

    private var recoveryLocalizationKey: String {
        switch self {
        case .invalidApplicationCertificate:
            return "provideCertificate"
        case .invalidContentIdentifier:
            return "provideContentIdentifier"
        case .invalidProtocolVersions:
            return "chooseProtocolVersions"
        case .deviceIdentifierRandomizationUnavailable:
            return "useSupportedDeviceIdentifierPolicy"
        case .invalidDeviceIdentifierSeed:
            return "provideDeviceIdentifierSeed"
        case .spcGenerationFailed:
            return "checkFairPlayInputs"
        case .licenseExchangeFailed, .invalidLicenseResponse:
            return "checkLicenseTransport"
        }
    }
}

@inline(__always)
private func streamingKeyLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: .module,
        comment: "AVFoundation HLS streaming FairPlay key diagnostic"
    )
}
#endif
