#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

protocol HLSFairPlayPersistenceRequesting: Sendable {
    func requestPersistence() throws
}

protocol HLSFairPlayPersistableRequestHandling: Sendable {
    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data
    ) async throws -> Data

    func makePersistableKey(
        from licenseResponse: Data
    ) throws -> Data

    func processPersistableKey(_ data: Data)
    func processFailure(_ error: NSError)
}

struct HLSFairPlayPersistenceRequestAdapter:
    HLSFairPlayPersistenceRequesting
{
    let request: AVContentKeyRequest

    func requestPersistence() throws {
        #if os(iOS)
        try request
            .respondByRequestingPersistableContentKeyRequestAndReturnError()
        #else
        try request.respondByRequestingPersistableContentKeyRequest()
        #endif
    }
}

struct HLSFairPlayPersistableRequestAdapter:
    HLSFairPlayPersistableRequestHandling
{
    let request: AVPersistableContentKeyRequest

    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            request.makeStreamingContentKeyRequestData(
                forApp: applicationCertificate,
                contentIdentifier: contentIdentifier,
                options: nil
            ) { data, error in
                do {
                    continuation.resume(
                        returning: try Self.resolveSPC(
                            data: data,
                            error: error
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func resolveSPC(
        data: Data?,
        error: (any Error)?
    ) throws -> Data {
        if let error {
            throw error
        }
        guard let data else {
            throw HLSFairPlayPersistentKeyError
                .spcGenerationFailed
        }
        return data
    }

    func makePersistableKey(
        from licenseResponse: Data
    ) throws -> Data {
        try request.persistableContentKey(
            fromKeyVendorResponse: licenseResponse,
            options: nil
        )
    }

    func processPersistableKey(_ data: Data) {
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
