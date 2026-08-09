#if canImport(AVFoundation) && !os(tvOS)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS FairPlay persistent keys")
struct HLSFairPlayPersistentKeyWorkflowTests {
    @Test("key identifiers and byte limits reject unsafe input")
    func validatesConfiguration() throws {
        #expect(throws: HLSFairPlayPersistentKeyError.invalidKeyIdentifier) {
            try HLSFairPlayKeyID(" \n")
        }
        #expect(throws: HLSFairPlayPersistentKeyError.invalidKeyIdentifier) {
            try HLSFairPlayKeyID(" episode-42 ")
        }
        #expect(throws: HLSFairPlayPersistentKeyError.invalidKeyIdentifier) {
            try HLSFairPlayKeyID(String(repeating: "a", count: 1_025))
        }
        let keyID = try HLSFairPlayKeyID("episode-42")
        let limits = HLSFairPlayPersistentKeyLimitPack(
            maximumApplicationCertificateBytes: 0,
            maximumContentIdentifierBytes: -1,
            maximumSPCBytes: .max,
            maximumLicenseResponseBytes: 0,
            maximumPersistableKeyBytes: .max
        )

        #expect(keyID.rawValue == "episode-42")
        #expect(limits.maximumApplicationCertificateBytes == 1)
        #expect(limits.maximumContentIdentifierBytes == 1)
        #expect(limits.maximumSPCBytes == 16 * 1_024 * 1_024)
        #expect(limits.maximumLicenseResponseBytes == 1)
        #expect(
            limits.maximumPersistableKeyBytes
                == 16 * 1_024 * 1_024
        )
    }

    @Test("stored keys fulfill requests without online acquisition")
    func restoresStoredKey() async throws {
        let keyID = try HLSFairPlayKeyID("stored")
        let storage = PersistentKeyStorageDouble(
            storedKeys: [keyID: Data("stored-key".utf8)]
        )
        let transport = LicenseTransportDouble(
            response: Data("unused".utf8)
        )
        let request = PersistableKeyRequestDouble()
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: transport,
            storage: storage
        )

        let disposition = try await workflow.fulfill(
            request,
            keyID: keyID,
            acquisition: nil
        )

        #expect(disposition == .restored)
        #expect(
            request.snapshot().processedKeys
                == [Data("stored-key".utf8)]
        )
        #expect(request.snapshot().failureCodes.isEmpty)
        #expect(await transport.requests().isEmpty)
        #expect(await storage.writeCount() == 0)
    }

    @Test("missing keys are acquired, stored, then fulfilled")
    func createsPersistentKey() async throws {
        let keyID = try HLSFairPlayKeyID("created")
        let storage = PersistentKeyStorageDouble()
        let transport = LicenseTransportDouble(
            response: Data("ckc".utf8)
        )
        let request = PersistableKeyRequestDouble(
            spc: Data("spc".utf8),
            persistableKey: Data("persistent".utf8)
        )
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: transport,
            storage: storage
        )
        let acquisition = HLSFairPlayPersistentKeyAcquisition(
            applicationCertificate: Data("certificate".utf8),
            contentIdentifier: Data("content".utf8)
        )

        let disposition = try await workflow.fulfill(
            request,
            keyID: keyID,
            acquisition: acquisition
        )

        #expect(disposition == .created)
        #expect(
            request.snapshot().applicationCertificate
                == acquisition.applicationCertificate
        )
        #expect(
            request.snapshot().contentIdentifier
                == acquisition.contentIdentifier
        )
        #expect(
            request.snapshot().licenseResponses
                == [Data("ckc".utf8)]
        )
        #expect(
            request.snapshot().processedKeys
                == [Data("persistent".utf8)]
        )
        #expect(request.snapshot().failureCodes.isEmpty)
        #expect(
            await transport.requests()
                == [
                    HLSFairPlayLicenseRequest(
                        keyID: keyID,
                        spcData: Data("spc".utf8)
                    )
                ]
        )
        #expect(
            try await storage.persistableContentKey(for: keyID)
                == Data("persistent".utf8)
        )
    }

    @Test("offline misses fail once with redacted diagnostics")
    func missingAcquisitionFailsRequest() async throws {
        let keyID = try HLSFairPlayKeyID("offline-miss")
        let storage = PersistentKeyStorageDouble()
        let transport = LicenseTransportDouble(
            response: Data("unused".utf8)
        )
        let request = PersistableKeyRequestDouble()
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: transport,
            storage: storage
        )

        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .persistableKeyUnavailable
        ) {
            try await workflow.fulfill(
                request,
                keyID: keyID,
                acquisition: nil
            )
        }

        #expect(request.snapshot().processedKeys.isEmpty)
        #expect(request.snapshot().failureCodes == [13])
        #expect(await transport.requests().isEmpty)
    }

    @Test("corrupt stored keys do not silently fall back to transport")
    func rejectsCorruptStoredKey() async throws {
        let keyID = try HLSFairPlayKeyID("corrupt")
        let storage = PersistentKeyStorageDouble(
            storedKeys: [keyID: Data()]
        )
        let transport = LicenseTransportDouble(
            response: Data("unused".utf8)
        )
        let request = PersistableKeyRequestDouble()
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: transport,
            storage: storage
        )

        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .invalidPersistableKey
        ) {
            try await workflow.fulfill(
                request,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data("cert".utf8),
                        contentIdentifier: Data("id".utf8)
                    )
            )
        }

        #expect(request.snapshot().failureCodes == [21])
        #expect(await transport.requests().isEmpty)
    }

    @Test("license failures preserve only stable classification")
    func mapsLicenseFailure() async throws {
        let keyID = try HLSFairPlayKeyID("license-failure")
        let storage = PersistentKeyStorageDouble()
        let transport = LicenseTransportDouble(
            response: Data(),
            fails: true
        )
        let request = PersistableKeyRequestDouble()
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: transport,
            storage: storage
        )

        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .licenseExchangeFailed
        ) {
            try await workflow.fulfill(
                request,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data("cert".utf8),
                        contentIdentifier: Data("id".utf8)
                    )
            )
        }

        #expect(request.snapshot().failureCodes == [18])
        #expect(request.snapshot().processedKeys.isEmpty)
    }

    @Test("oversized license responses fail before key conversion")
    func boundsLicenseResponse() async throws {
        let keyID = try HLSFairPlayKeyID("large-license")
        let storage = PersistentKeyStorageDouble()
        let transport = LicenseTransportDouble(
            response: Data(repeating: 1, count: 2)
        )
        let request = PersistableKeyRequestDouble()
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: transport,
            storage: storage,
            configuration: .advanced(
                limits: HLSFairPlayPersistentKeyLimitPack(
                    maximumLicenseResponseBytes: 1
                )
            )
        )

        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .invalidLicenseResponse
        ) {
            try await workflow.fulfill(
                request,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data("cert".utf8),
                        contentIdentifier: Data("id".utf8)
                    )
            )
        }

        #expect(request.snapshot().licenseResponses.isEmpty)
        #expect(request.snapshot().failureCodes == [19])
    }

    @Test("invalid acquisition inputs fail before SPC generation")
    func validatesAcquisitionInputs() async throws {
        let keyID = try HLSFairPlayKeyID("invalid-acquisition")
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: LicenseTransportDouble(
                response: Data("unused".utf8)
            ),
            storage: PersistentKeyStorageDouble()
        )
        let certificateRequest = PersistableKeyRequestDouble()
        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .invalidApplicationCertificate
        ) {
            try await workflow.fulfill(
                certificateRequest,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data(),
                        contentIdentifier: Data("id".utf8)
                    )
            )
        }
        #expect(certificateRequest.snapshot().failureCodes == [11])
        #expect(
            certificateRequest.snapshot()
                .applicationCertificate == nil
        )

        let identifierRequest = PersistableKeyRequestDouble()
        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .invalidContentIdentifier
        ) {
            try await workflow.fulfill(
                identifierRequest,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data("cert".utf8),
                        contentIdentifier: Data()
                    )
            )
        }
        #expect(identifierRequest.snapshot().failureCodes == [12])
        #expect(
            identifierRequest.snapshot()
                .applicationCertificate == nil
        )
    }

    @Test("key conversion failures do not write or fulfill")
    func mapsPersistableKeyCreationFailure() async throws {
        let keyID = try HLSFairPlayKeyID("conversion-failure")
        let storage = PersistentKeyStorageDouble()
        let request = PersistableKeyRequestDouble(
            failsPersistableKeyCreation: true
        )
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: LicenseTransportDouble(
                response: Data("ckc".utf8)
            ),
            storage: storage
        )

        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .persistableKeyCreationFailed
        ) {
            try await workflow.fulfill(
                request,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data("cert".utf8),
                        contentIdentifier: Data("id".utf8)
                    )
            )
        }

        #expect(request.snapshot().failureCodes == [20])
        #expect(request.snapshot().processedKeys.isEmpty)
        #expect(await storage.writeCount() == 0)
    }

    @Test("storage failures preserve read and write stages")
    func mapsStorageFailures() async throws {
        let keyID = try HLSFairPlayKeyID("storage-failure")
        let readRequest = PersistableKeyRequestDouble()
        let readWorkflow = HLSFairPlayPersistentKeyWorkflow(
            transport: LicenseTransportDouble(
                response: Data("unused".utf8)
            ),
            storage: PersistentKeyStorageDouble(
                failsRead: true
            )
        )
        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .storageReadFailed
        ) {
            try await readWorkflow.fulfill(
                readRequest,
                keyID: keyID,
                acquisition: nil
            )
        }
        #expect(readRequest.snapshot().failureCodes == [15])

        let writeRequest = PersistableKeyRequestDouble()
        let writeWorkflow = HLSFairPlayPersistentKeyWorkflow(
            transport: LicenseTransportDouble(
                response: Data("ckc".utf8)
            ),
            storage: PersistentKeyStorageDouble(
                failsWrite: true
            )
        )
        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .storageWriteFailed
        ) {
            try await writeWorkflow.fulfill(
                writeRequest,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data("cert".utf8),
                        contentIdentifier: Data("id".utf8)
                    )
            )
        }
        #expect(writeRequest.snapshot().failureCodes == [16])
        #expect(writeRequest.snapshot().processedKeys.isEmpty)
    }

    @Test("URL cancellation remains caller cancellation")
    func preservesTransportCancellation() async throws {
        let keyID = try HLSFairPlayKeyID("cancelled")
        let request = PersistableKeyRequestDouble()
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: LicenseTransportDouble(
                response: Data(),
                cancels: true
            ),
            storage: PersistentKeyStorageDouble()
        )

        await #expect(throws: CancellationError.self) {
            try await workflow.fulfill(
                request,
                keyID: keyID,
                acquisition:
                    HLSFairPlayPersistentKeyAcquisition(
                        applicationCertificate: Data("cert".utf8),
                        contentIdentifier: Data("id".utf8)
                    )
            )
        }

        #expect(request.snapshot().processedKeys.isEmpty)
        #expect(request.snapshot().failureCodes == [1])
    }

    @Test("updated keys are validated and forwarded to app storage")
    func storesUpdatedKey() async throws {
        let keyID = try HLSFairPlayKeyID("updated")
        let storage = PersistentKeyStorageDouble()
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: LicenseTransportDouble(
                response: Data("unused".utf8)
            ),
            storage: storage
        )

        await #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .invalidPersistableKey
        ) {
            try await workflow.storeUpdatedPersistableContentKey(
                Data(),
                for: keyID
            )
        }
        try await workflow.storeUpdatedPersistableContentKey(
            Data("replacement".utf8),
            for: keyID
        )

        #expect(
            try await storage.persistableContentKey(for: keyID)
                == Data("replacement".utf8)
        )
        #expect(await storage.writeCount() == 1)
    }

    @Test("persistence promotion failures remain typed")
    func mapsPromotionFailure() throws {
        let workflow = HLSFairPlayPersistentKeyWorkflow(
            transport: LicenseTransportDouble(
                response: Data("unused".utf8)
            ),
            storage: PersistentKeyStorageDouble()
        )

        #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .persistentRequestRejected
        ) {
            try workflow.requestPersistence(
                PersistenceRequestDouble(fails: true)
            )
        }
        try workflow.requestPersistence(
            PersistenceRequestDouble(fails: false)
        )
    }

    @Test("SPC callbacks prioritize errors over partial data")
    func validatesSPCCallback() throws {
        let data = Data("partial".utf8)

        #expect(
            throws: PersistentKeyTestError.failed
        ) {
            try HLSFairPlayPersistableRequestAdapter.resolveSPC(
                data: data,
                error: PersistentKeyTestError.failed
            )
        }
        #expect(
            throws:
                HLSFairPlayPersistentKeyError
                .spcGenerationFailed
        ) {
            try HLSFairPlayPersistableRequestAdapter.resolveSPC(
                data: nil,
                error: nil
            )
        }
        #expect(
            try HLSFairPlayPersistableRequestAdapter.resolveSPC(
                data: data,
                error: nil
            ) == data
        )
    }

    @Test("persistent-key failures provide actionable localization")
    func diagnostics() {
        let error =
            HLSFairPlayPersistentKeyError
            .invalidApplicationCertificate
        #expect(!error.localizedDescription.isEmpty)
        #expect(error.recoverySuggestion?.isEmpty == false)
        #expect(!error.localizedDescription.contains("certificate-data"))
    }
}

private enum PersistentKeyTestError: Error {
    case failed
}

private struct PersistenceRequestDouble:
    HLSFairPlayPersistenceRequesting
{
    let fails: Bool

    func requestPersistence() throws {
        if fails {
            throw PersistentKeyTestError.failed
        }
    }
}

private final class PersistableKeyRequestDouble:
    HLSFairPlayPersistableRequestHandling,
    @unchecked Sendable
{
    struct Snapshot {
        let applicationCertificate: Data?
        let contentIdentifier: Data?
        let licenseResponses: [Data]
        let processedKeys: [Data]
        let failureCodes: [Int]
    }

    private let lock = NSLock()
    private let spc: Data
    private let persistableKey: Data
    private let failsPersistableKeyCreation: Bool
    private var applicationCertificate: Data?
    private var contentIdentifier: Data?
    private var licenseResponses: [Data] = []
    private var processedKeys: [Data] = []
    private var failureCodes: [Int] = []

    init(
        spc: Data = Data("spc".utf8),
        persistableKey: Data = Data("persistable".utf8),
        failsPersistableKeyCreation: Bool = false
    ) {
        self.spc = spc
        self.persistableKey = persistableKey
        self.failsPersistableKeyCreation =
            failsPersistableKeyCreation
    }

    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data
    ) async throws -> Data {
        lock.withLock {
            self.applicationCertificate = applicationCertificate
            self.contentIdentifier = contentIdentifier
        }
        return spc
    }

    func makePersistableKey(
        from licenseResponse: Data
    ) throws -> Data {
        lock.withLock {
            licenseResponses.append(licenseResponse)
        }
        if failsPersistableKeyCreation {
            throw PersistentKeyTestError.failed
        }
        return persistableKey
    }

    func processPersistableKey(_ data: Data) {
        lock.withLock {
            processedKeys.append(data)
        }
    }

    func processFailure(_ error: NSError) {
        lock.withLock {
            failureCodes.append(error.code)
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                applicationCertificate: applicationCertificate,
                contentIdentifier: contentIdentifier,
                licenseResponses: licenseResponses,
                processedKeys: processedKeys,
                failureCodes: failureCodes
            )
        }
    }
}

private actor LicenseTransportDouble:
    HLSFairPlayLicenseTransporting
{
    private let response: Data
    private let fails: Bool
    private let cancels: Bool
    private var recordedRequests: [HLSFairPlayLicenseRequest] = []

    init(
        response: Data,
        fails: Bool = false,
        cancels: Bool = false
    ) {
        self.response = response
        self.fails = fails
        self.cancels = cancels
    }

    func contentKeyContext(
        for request: HLSFairPlayLicenseRequest
    ) throws -> Data {
        recordedRequests.append(request)
        if cancels {
            throw URLError(.cancelled)
        }
        if fails {
            throw PersistentKeyTestError.failed
        }
        return response
    }

    func requests() -> [HLSFairPlayLicenseRequest] {
        recordedRequests
    }
}

private actor PersistentKeyStorageDouble:
    HLSFairPlayPersistentKeyStoring
{
    private var storedKeys: [HLSFairPlayKeyID: Data]
    private let failsRead: Bool
    private let failsWrite: Bool
    private var recordedWriteCount = 0

    init(
        storedKeys: [HLSFairPlayKeyID: Data] = [:],
        failsRead: Bool = false,
        failsWrite: Bool = false
    ) {
        self.storedKeys = storedKeys
        self.failsRead = failsRead
        self.failsWrite = failsWrite
    }

    func persistableContentKey(
        for keyID: HLSFairPlayKeyID
    ) throws -> Data? {
        if failsRead {
            throw PersistentKeyTestError.failed
        }
        return storedKeys[keyID]
    }

    func storePersistableContentKey(
        _ data: Data,
        for keyID: HLSFairPlayKeyID
    ) throws {
        if failsWrite {
            throw PersistentKeyTestError.failed
        }
        storedKeys[keyID] = data
        recordedWriteCount += 1
    }

    func writeCount() -> Int {
        recordedWriteCount
    }
}
#endif
