#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

/// Submits initial and renewing FairPlay streaming-key responses.
///
/// The workflow retains application-owned license transport, but never owns or
/// logs certificates, SPC, CKC, credentials, or content identifiers. A return
/// value means that AVFoundation received the response; use its success
/// delegate callback to emit a separate acceptance event.
public struct HLSFairPlayStreamingKeyWorkflow: Sendable {
    private static let maximumProtocolVersionCount = 16

    private let transport: any HLSFairPlayLicenseTransporting
    private let configuration: HLSFairPlayStreamingKeyConfiguration

    /// Creates a workflow with application-owned license transport.
    public init(
        transport: any HLSFairPlayLicenseTransporting,
        configuration: HLSFairPlayStreamingKeyConfiguration =
            .safeDefaults()
    ) {
        self.transport = transport
        self.configuration = configuration
    }

    /// Generates an SPC, exchanges it for a bounded CKC, and submits it.
    ///
    /// Call this from both the initial and renewing content-key delegate
    /// callbacks, passing the matching `purpose`. Once called, the method owns
    /// success or failure completion for `request`.
    public func fulfill(
        _ request: AVContentKeyRequest,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayStreamingKeyAcquisition,
        purpose: HLSFairPlayLicenseRequestPurpose = .initial
    ) async throws -> HLSFairPlayContentKeyEvent {
        try await fulfill(
            HLSFairPlayStreamingRequestAdapter(request: request),
            keyID: keyID,
            acquisition: acquisition,
            purpose: purpose
        )
    }

    func fulfill(
        _ request: any HLSFairPlayStreamingRequestHandling,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayStreamingKeyAcquisition,
        purpose: HLSFairPlayLicenseRequestPurpose
    ) async throws -> HLSFairPlayContentKeyEvent {
        do {
            let event = try await performFulfillment(
                request,
                keyID: keyID,
                acquisition: acquisition,
                purpose: purpose
            )
            return event
        } catch is CancellationError {
            request.processFailure(Self.failureError(code: 1))
            throw CancellationError()
        } catch let error as HLSFairPlayStreamingKeyError {
            request.processFailure(
                Self.failureError(code: Self.errorCode(error))
            )
            throw error
        } catch {
            request.processFailure(Self.failureError(code: 2))
            throw HLSFairPlayStreamingKeyError.licenseExchangeFailed
        }
    }

    private func performFulfillment(
        _ request: any HLSFairPlayStreamingRequestHandling,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayStreamingKeyAcquisition,
        purpose: HLSFairPlayLicenseRequestPurpose
    ) async throws -> HLSFairPlayContentKeyEvent {
        try validate(acquisition)
        let spc: Data
        do {
            spc = try await request.makeSPC(
                applicationCertificate:
                    acquisition.applicationCertificate,
                contentIdentifier: acquisition.contentIdentifier,
                supportedProtocolVersions:
                    acquisition.supportedProtocolVersions,
                deviceIdentifierPolicy:
                    acquisition.deviceIdentifierPolicy
            )
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw HLSFairPlayStreamingKeyError.spcGenerationFailed
        }
        guard
            !spc.isEmpty,
            spc.count <= configuration.limits.maximumSPCBytes
        else {
            throw HLSFairPlayStreamingKeyError.spcGenerationFailed
        }
        try Task.checkCancellation()

        let licenseResponse: Data
        do {
            licenseResponse = try await transport.contentKeyContext(
                for: HLSFairPlayLicenseRequest(
                    keyID: keyID,
                    spcData: spc,
                    purpose: purpose
                )
            )
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw HLSFairPlayStreamingKeyError.licenseExchangeFailed
        }
        guard
            !licenseResponse.isEmpty,
            licenseResponse.count
                <= configuration.limits.maximumLicenseResponseBytes
        else {
            throw HLSFairPlayStreamingKeyError.invalidLicenseResponse
        }
        try Task.checkCancellation()
        request.processStreamingKey(licenseResponse)
        return .responseSubmitted(purpose)
    }

    private func validate(
        _ acquisition: HLSFairPlayStreamingKeyAcquisition
    ) throws {
        guard
            !acquisition.applicationCertificate.isEmpty,
            acquisition.applicationCertificate.count
                <= configuration.limits
                .maximumApplicationCertificateBytes
        else {
            throw HLSFairPlayStreamingKeyError
                .invalidApplicationCertificate
        }
        guard
            !acquisition.contentIdentifier.isEmpty,
            acquisition.contentIdentifier.count
                <= configuration.limits.maximumContentIdentifierBytes
        else {
            throw HLSFairPlayStreamingKeyError.invalidContentIdentifier
        }
        let protocolVersions = acquisition.supportedProtocolVersions
        guard
            !protocolVersions.isEmpty,
            protocolVersions.count <= Self.maximumProtocolVersionCount,
            protocolVersions.allSatisfy({ $0 > 0 }),
            Set(protocolVersions).count == protocolVersions.count
        else {
            throw HLSFairPlayStreamingKeyError.invalidProtocolVersions
        }
        if let failure =
            HLSFairPlaySPCOptions.validationFailure(
                for: acquisition.deviceIdentifierPolicy,
                isRandomizationSupported:
                    HLSFairPlaySPCOptions
                    .supportsDeviceIdentifierRandomization
            )
        {
            switch failure {
            case .unavailable:
                throw HLSFairPlayStreamingKeyError
                    .deviceIdentifierRandomizationUnavailable
            case .invalidSeed:
                throw HLSFairPlayStreamingKeyError
                    .invalidDeviceIdentifierSeed
            }
        }
    }

    private static func failureError(code: Int) -> NSError {
        NSError(
            domain:
                "InnoNetworkHLSAVFoundation."
                + "HLSFairPlayStreamingKeyWorkflow",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The FairPlay streaming-key workflow failed."
            ]
        )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return true
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NSURLErrorDomain
            && cocoaError.code == NSURLErrorCancelled
    }

    private static func errorCode(
        _ error: HLSFairPlayStreamingKeyError
    ) -> Int {
        switch error {
        case .invalidApplicationCertificate:
            return 11
        case .invalidContentIdentifier:
            return 12
        case .invalidProtocolVersions:
            return 22
        case .deviceIdentifierRandomizationUnavailable:
            return 23
        case .invalidDeviceIdentifierSeed:
            return 24
        case .spcGenerationFailed:
            return 17
        case .licenseExchangeFailed:
            return 18
        case .invalidLicenseResponse:
            return 19
        }
    }
}
#endif
