#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

/// Coordinates restore-or-create FairPlay persistent-key requests.
///
/// The workflow retains transport and storage services, but never independently
/// persists or logs certificate, SPC, license-response, or key bytes.
public struct HLSFairPlayPersistentKeyWorkflow: Sendable {
    private let transport: any HLSFairPlayLicenseTransporting
    private let storage: any HLSFairPlayPersistentKeyStoring
    private let configuration: HLSFairPlayPersistentKeyConfiguration

    /// Creates a workflow with application-owned transport and storage.
    public init(
        transport: any HLSFairPlayLicenseTransporting,
        storage: any HLSFairPlayPersistentKeyStoring,
        configuration: HLSFairPlayPersistentKeyConfiguration =
            .safeDefaults()
    ) {
        self.transport = transport
        self.storage = storage
        self.configuration = configuration
    }

    /// Promotes a streaming request to a persistable key request.
    ///
    /// The session delegate must implement its persistable-request callback
    /// before calling this method.
    public func requestPersistence(
        for request: AVContentKeyRequest
    ) throws {
        try requestPersistence(
            HLSFairPlayPersistenceRequestAdapter(
                request: request
            )
        )
    }

    /// Restores or creates a persistable key and fulfills the request.
    ///
    /// `acquisition` is unused when app-owned storage returns a valid key. If
    /// no key is stored, acquisition inputs are required for SPC generation
    /// and application-owned license transport. Once called, this method
    /// fully owns success or failure completion for `request`.
    public func fulfill(
        _ request: AVPersistableContentKeyRequest,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayPersistentKeyAcquisition? = nil
    ) async throws -> HLSFairPlayPersistentKeyDisposition {
        try await fulfill(
            HLSFairPlayPersistableRequestAdapter(
                request: request
            ),
            keyID: keyID,
            acquisition: acquisition
        )
    }

    /// Stores a replacement key delivered by AVFoundation's update callback.
    ///
    /// The workflow validates and forwards the data but leaves durable storage,
    /// protection class, access control, and deletion policy with the app.
    public func storeUpdatedPersistableContentKey(
        _ data: Data,
        for keyID: HLSFairPlayKeyID
    ) async throws {
        guard isValidPersistableKey(data) else {
            throw HLSFairPlayPersistentKeyError.invalidPersistableKey
        }
        do {
            try await storage.storePersistableContentKey(
                data,
                for: keyID
            )
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw HLSFairPlayPersistentKeyError.storageWriteFailed
        }
    }

    func requestPersistence(
        _ request: any HLSFairPlayPersistenceRequesting
    ) throws {
        do {
            try request.requestPersistence()
        } catch {
            throw
                HLSFairPlayPersistentKeyError
                .persistentRequestRejected
        }
    }

    func fulfill(
        _ request: any HLSFairPlayPersistableRequestHandling,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayPersistentKeyAcquisition?
    ) async throws -> HLSFairPlayPersistentKeyDisposition {
        do {
            return try await performFulfillment(
                request,
                keyID: keyID,
                acquisition: acquisition
            )
        } catch is CancellationError {
            request.processFailure(
                Self.failureError(code: 1)
            )
            throw CancellationError()
        } catch let error as HLSFairPlayPersistentKeyError {
            request.processFailure(
                Self.failureError(
                    code: Self.errorCode(error)
                )
            )
            throw error
        } catch {
            request.processFailure(
                Self.failureError(code: 2)
            )
            throw HLSFairPlayPersistentKeyError.licenseExchangeFailed
        }
    }

    private func performFulfillment(
        _ request: any HLSFairPlayPersistableRequestHandling,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayPersistentKeyAcquisition?
    ) async throws -> HLSFairPlayPersistentKeyDisposition {
        let storedKey: Data?
        do {
            storedKey = try await storage.persistableContentKey(
                for: keyID
            )
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw HLSFairPlayPersistentKeyError.storageReadFailed
        }
        if let storedKey {
            guard isValidPersistableKey(storedKey) else {
                throw HLSFairPlayPersistentKeyError
                    .invalidPersistableKey
            }
            try Task.checkCancellation()
            request.processPersistableKey(storedKey)
            return .restored
        }

        guard let acquisition else {
            throw HLSFairPlayPersistentKeyError
                .persistableKeyUnavailable
        }
        try validate(acquisition)
        let spc: Data
        do {
            spc = try await request.makeSPC(
                applicationCertificate:
                    acquisition.applicationCertificate,
                contentIdentifier:
                    acquisition.contentIdentifier
            )
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw HLSFairPlayPersistentKeyError
                .spcGenerationFailed
        }
        guard
            !spc.isEmpty,
            spc.count <= configuration.limits.maximumSPCBytes
        else {
            throw HLSFairPlayPersistentKeyError
                .spcGenerationFailed
        }

        let licenseResponse: Data
        do {
            licenseResponse = try await transport.contentKeyContext(
                for: HLSFairPlayLicenseRequest(
                    keyID: keyID,
                    spcData: spc
                )
            )
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw HLSFairPlayPersistentKeyError
                .licenseExchangeFailed
        }
        guard
            !licenseResponse.isEmpty,
            licenseResponse.count
                <= configuration.limits
                .maximumLicenseResponseBytes
        else {
            throw HLSFairPlayPersistentKeyError
                .invalidLicenseResponse
        }

        let persistableKey: Data
        do {
            persistableKey = try request.makePersistableKey(
                from: licenseResponse
            )
        } catch {
            throw HLSFairPlayPersistentKeyError
                .persistableKeyCreationFailed
        }
        guard isValidPersistableKey(persistableKey) else {
            throw HLSFairPlayPersistentKeyError
                .invalidPersistableKey
        }
        do {
            try await storage.storePersistableContentKey(
                persistableKey,
                for: keyID
            )
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw HLSFairPlayPersistentKeyError.storageWriteFailed
        }
        try Task.checkCancellation()
        request.processPersistableKey(persistableKey)
        return .created
    }

    private func validate(
        _ acquisition: HLSFairPlayPersistentKeyAcquisition
    ) throws {
        guard
            !acquisition.applicationCertificate.isEmpty,
            acquisition.applicationCertificate.count
                <= configuration.limits
                .maximumApplicationCertificateBytes
        else {
            throw HLSFairPlayPersistentKeyError
                .invalidApplicationCertificate
        }
        guard
            !acquisition.contentIdentifier.isEmpty,
            acquisition.contentIdentifier.count
                <= configuration.limits
                .maximumContentIdentifierBytes
        else {
            throw HLSFairPlayPersistentKeyError
                .invalidContentIdentifier
        }
    }

    private func isValidPersistableKey(_ data: Data) -> Bool {
        !data.isEmpty
            && data.count
                <= configuration.limits
                .maximumPersistableKeyBytes
    }

    private static func failureError(code: Int) -> NSError {
        NSError(
            domain:
                "InnoNetworkHLSAVFoundation."
                + "HLSFairPlayPersistentKeyWorkflow",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The FairPlay persistent-key workflow failed."
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
        _ error: HLSFairPlayPersistentKeyError
    ) -> Int {
        switch error {
        case .invalidKeyIdentifier:
            return 10
        case .invalidApplicationCertificate:
            return 11
        case .invalidContentIdentifier:
            return 12
        case .persistableKeyUnavailable:
            return 13
        case .persistentRequestRejected:
            return 14
        case .storageReadFailed:
            return 15
        case .storageWriteFailed:
            return 16
        case .spcGenerationFailed:
            return 17
        case .licenseExchangeFailed:
            return 18
        case .invalidLicenseResponse:
            return 19
        case .persistableKeyCreationFailed:
            return 20
        case .invalidPersistableKey:
            return 21
        }
    }
}
#endif
