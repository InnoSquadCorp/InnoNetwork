#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS FairPlay device identifiers")
struct HLSFairPlayDeviceIdentifierPolicyTests {
    @Test("policy validation is bounded and availability aware")
    func validatesPolicy() {
        #expect(
            HLSFairPlaySPCOptions.validationFailure(
                for: .systemDefault,
                isRandomizationSupported: false
            ) == nil
        )
        #expect(
            HLSFairPlaySPCOptions.validationFailure(
                for: .randomized,
                isRandomizationSupported: false
            ) == .unavailable
        )
        for byteCount in [0, 15, 17] {
            #expect(
                HLSFairPlaySPCOptions.validationFailure(
                    for: .randomizedWithSeed(
                        Data(repeating: 1, count: byteCount)
                    ),
                    isRandomizationSupported: true
                ) == .invalidSeed
            )
        }
        #expect(
            HLSFairPlaySPCOptions.validationFailure(
                for: .randomizedWithSeed(Data(repeating: 1, count: 16)),
                isRandomizationSupported: true
            ) == nil
        )
    }

    @Test("system-default options retain only protocol versions")
    func makesSystemDefaultOptions() throws {
        let options = try HLSFairPlaySPCOptions.make(
            protocolVersions: [3, 2, 1],
            deviceIdentifierPolicy: .systemDefault
        )

        #expect(
            options[AVContentKeyRequestProtocolVersionsKey] as? [Int]
                == [3, 2, 1]
        )
        #expect(options.count == 1)
    }

    @Test("randomized options map to AVFoundation on supported systems")
    func makesRandomizedOptions() throws {
        guard
            #available(macOS 26,
            iOS 26,
            watchOS 26,
            visionOS 26,
            *)
        else {
            #expect(
                throws:
                    HLSFairPlayDeviceIdentifierPolicyFailure.unavailable
            ) {
                try HLSFairPlaySPCOptions.make(
                    protocolVersions: [1],
                    deviceIdentifierPolicy: .randomized
                )
            }
            return
        }

        let randomizedOptions = try HLSFairPlaySPCOptions.make(
            protocolVersions: [1],
            deviceIdentifierPolicy: .randomized
        )
        #expect(
            randomizedOptions[
                AVContentKeyRequestShouldRandomizeDeviceIdentifierKey
            ] as? Bool == true
        )
        #expect(
            randomizedOptions[
                AVContentKeyRequestRandomDeviceIdentifierSeedKey
            ] == nil
        )

        let seed = Data(repeating: 7, count: 16)
        let seededOptions = try HLSFairPlaySPCOptions.make(
            protocolVersions: [1],
            deviceIdentifierPolicy: .randomizedWithSeed(seed)
        )
        #expect(
            seededOptions[
                AVContentKeyRequestShouldRandomizeDeviceIdentifierKey
            ] as? Bool == true
        )
        #expect(
            seededOptions[
                AVContentKeyRequestRandomDeviceIdentifierSeedKey
            ] as? Data == seed
        )
    }
}
#endif
