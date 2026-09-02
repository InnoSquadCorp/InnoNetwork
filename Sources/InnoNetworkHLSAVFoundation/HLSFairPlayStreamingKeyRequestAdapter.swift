#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

protocol HLSFairPlayStreamingRequestHandling: Sendable {
    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data,
        supportedProtocolVersions: [Int],
        deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy
    ) async throws -> HLSFairPlayStreamingSPCResult

    func processStreamingKey(_ data: Data)
    func processFailure(_ error: NSError)
}

enum HLSFairPlayStreamingSPCResult: Equatable, Sendable {
    case generated(Data)
    case fulfilledByAdvisoryKey
}

struct HLSFairPlayStreamingRequestAdapter:
    HLSFairPlayStreamingRequestHandling
{
    let request: AVContentKeyRequest
    let advisoryKeyPolicy: HLSFairPlayAdvisoryKeyPolicy

    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data,
        supportedProtocolVersions: [Int],
        deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy
    ) async throws -> HLSFairPlayStreamingSPCResult {
        let options = try HLSFairPlaySPCOptions.make(
            protocolVersions: supportedProtocolVersions,
            deviceIdentifierPolicy: deviceIdentifierPolicy
        )
        switch advisoryKeyPolicy {
        case .disabled:
            return try await makeRequiredSPC(
                applicationCertificate: applicationCertificate,
                contentIdentifier: contentIdentifier,
                options: options
            )
        case .enabledForStreamingOnly:
            return try await makeOptionalSPC(
                applicationCertificate: applicationCertificate,
                contentIdentifier: contentIdentifier,
                options: options
            )
        }
    }

    private func makeRequiredSPC(
        applicationCertificate: Data,
        contentIdentifier: Data,
        options: [String: Any]
    ) async throws -> HLSFairPlayStreamingSPCResult {
        return try await withCheckedThrowingContinuation { continuation in
            request.makeStreamingContentKeyRequestData(
                forApp: applicationCertificate,
                contentIdentifier: contentIdentifier,
                options: options
            ) { data, error in
                do {
                    continuation.resume(
                        returning: try Self.resolveSPC(
                            data: data,
                            error: error,
                            canBeFulfilledWithAdvisoryKey: false
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeOptionalSPC(
        applicationCertificate: Data,
        contentIdentifier: Data,
        options: [String: Any]
    ) async throws -> HLSFairPlayStreamingSPCResult {
        #if compiler(>=6.4) && os(iOS) && !targetEnvironment(macCatalyst)
        guard #available(iOS 27, *) else {
            throw HLSFairPlayStreamingKeyError.spcGenerationFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            request.makeOptionalStreamingContentKeyRequestData(
                forApp: applicationCertificate,
                contentIdentifier: contentIdentifier,
                options: options
            ) { data, error in
                do {
                    continuation.resume(
                        returning: try Self.resolveSPC(
                            data: data,
                            error: error,
                            canBeFulfilledWithAdvisoryKey:
                                request.canBeFulfilledWithAdvisoryKey
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        throw HLSFairPlayStreamingKeyError.spcGenerationFailed
        #endif
    }

    static func resolveSPC(
        data: Data?,
        error: (any Error)?,
        canBeFulfilledWithAdvisoryKey: Bool
    ) throws -> HLSFairPlayStreamingSPCResult {
        if let error {
            throw error
        }
        if let data {
            return .generated(data)
        }
        if canBeFulfilledWithAdvisoryKey {
            return .fulfilledByAdvisoryKey
        }
        throw HLSFairPlayStreamingKeyError.spcGenerationFailed
    }

    func processStreamingKey(_ data: Data) {
        request.processContentKeyResponse(
            AVContentKeyResponse(
                fairPlayStreamingKeyResponseData: data
            )
        )
    }

    func processFailure(_ error: NSError) {
        request.processContentKeyResponseError(error)
    }
}
#endif
