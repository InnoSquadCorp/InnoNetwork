#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

/// Controls whether FairPlay keeps or randomizes its anonymized device ID.
///
/// Randomization changes the device identifier embedded in the SPC. Enable it
/// only after the application's key server and entitlement policy no longer
/// depend on a stable per-device value.
public enum HLSFairPlayDeviceIdentifierPolicy: Equatable, Sendable {
    /// Preserves AVFoundation's default device-identifier behavior.
    case systemDefault

    /// Lets AVFoundation generate the randomization seed.
    case randomized

    /// Uses an application-generated, exactly 16-byte randomization seed.
    ///
    /// Treat the seed as sensitive application data. Generate it with a
    /// cryptographically secure random source and do not log it.
    case randomizedWithSeed(Data)
}

enum HLSFairPlayDeviceIdentifierPolicyFailure: Equatable {
    case unavailable
    case invalidSeed
}

enum HLSFairPlaySPCOptions {
    static var supportsDeviceIdentifierRandomization: Bool {
        if #available(macOS 26,
        iOS 26,
        watchOS 26,
        visionOS 26,
        *) {
            return true
        }
        return false
    }

    static func validationFailure(
        for policy: HLSFairPlayDeviceIdentifierPolicy,
        isRandomizationSupported: Bool
    ) -> HLSFairPlayDeviceIdentifierPolicyFailure? {
        switch policy {
        case .systemDefault:
            return nil
        case .randomized:
            return isRandomizationSupported ? nil : .unavailable
        case .randomizedWithSeed(let seed):
            guard seed.count == 16 else {
                return .invalidSeed
            }
            return isRandomizationSupported ? nil : .unavailable
        }
    }

    static func make(
        protocolVersions: [Int],
        deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy
    ) throws -> [String: Any] {
        if let failure = validationFailure(
            for: deviceIdentifierPolicy,
            isRandomizationSupported:
                supportsDeviceIdentifierRandomization
        ) {
            throw failure
        }

        var options: [String: Any] = [
            AVContentKeyRequestProtocolVersionsKey: protocolVersions
        ]
        if #available(macOS 26,
        iOS 26,
        watchOS 26,
        visionOS 26,
        *) {
            applyDeviceIdentifierPolicy(
                deviceIdentifierPolicy,
                to: &options
            )
        }
        return options
    }

    @available(macOS 26, iOS 26, watchOS 26, visionOS 26, *)
    private static func applyDeviceIdentifierPolicy(
        _ policy: HLSFairPlayDeviceIdentifierPolicy,
        to options: inout [String: Any]
    ) {
        switch policy {
        case .systemDefault:
            break
        case .randomized:
            options[
                AVContentKeyRequestShouldRandomizeDeviceIdentifierKey
            ] = true
        case .randomizedWithSeed(let seed):
            options[
                AVContentKeyRequestShouldRandomizeDeviceIdentifierKey
            ] = true
            options[
                AVContentKeyRequestRandomDeviceIdentifierSeedKey
            ] = seed
        }
    }
}

extension HLSFairPlayDeviceIdentifierPolicyFailure: Error {}
#endif
