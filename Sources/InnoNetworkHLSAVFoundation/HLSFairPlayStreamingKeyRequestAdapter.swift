#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

protocol HLSFairPlayStreamingRequestHandling: Sendable {
    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data,
        supportedProtocolVersions: [Int]
    ) async throws -> Data

    func processStreamingKey(_ data: Data)
    func processFailure(_ error: NSError)
}

struct HLSFairPlayStreamingRequestAdapter:
    HLSFairPlayStreamingRequestHandling
{
    let request: AVContentKeyRequest

    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data,
        supportedProtocolVersions: [Int]
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            request.makeStreamingContentKeyRequestData(
                forApp: applicationCertificate,
                contentIdentifier: contentIdentifier,
                options: [
                    AVContentKeyRequestProtocolVersionsKey:
                        supportedProtocolVersions
                ]
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
            throw HLSFairPlayStreamingKeyError.spcGenerationFailed
        }
        return data
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
