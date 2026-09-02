#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS FairPlay streaming keys")
struct HLSFairPlayStreamingKeyWorkflowTests {
    @Test("streaming-key inputs and byte limits are bounded")
    func validatesConfiguration() {
        let limits = HLSFairPlayStreamingKeyLimitPack(
            maximumApplicationCertificateBytes: 0,
            maximumContentIdentifierBytes: -1,
            maximumSPCBytes: .max,
            maximumLicenseResponseBytes: 0
        )
        let acquisition = HLSFairPlayStreamingKeyAcquisition(
            applicationCertificate: Data("certificate".utf8),
            contentIdentifier: Data("content".utf8)
        )

        #expect(limits.maximumApplicationCertificateBytes == 1)
        #expect(limits.maximumContentIdentifierBytes == 1)
        #expect(limits.maximumSPCBytes == 16 * 1_024 * 1_024)
        #expect(limits.maximumLicenseResponseBytes == 1)
        #expect(acquisition.supportedProtocolVersions == [1])
        #expect(acquisition.deviceIdentifierPolicy == .systemDefault)
    }

    @Test("initial and renewing requests retain typed purpose through transport")
    func submitsInitialAndRenewingResponses() async throws {
        let keyID = try HLSFairPlayKeyID("streaming")
        let transport = StreamingLicenseTransportDouble(
            response: Data("ckc".utf8)
        )
        let workflow = HLSFairPlayStreamingKeyWorkflow(
            transport: transport
        )
        let acquisition = HLSFairPlayStreamingKeyAcquisition(
            applicationCertificate: Data("certificate".utf8),
            contentIdentifier: Data("content".utf8),
            supportedProtocolVersions: [3, 2, 1]
        )

        for purpose in [
            HLSFairPlayLicenseRequestPurpose.initial,
            .renewal,
        ] {
            let request = StreamingKeyRequestDouble(
                spc: Data("spc-\(purpose)".utf8)
            )
            let event = try await workflow.fulfill(
                request,
                keyID: keyID,
                acquisition: acquisition,
                purpose: purpose
            )

            #expect(event == .responseSubmitted(purpose))
            #expect(
                request.snapshot().applicationCertificate
                    == acquisition.applicationCertificate
            )
            #expect(
                request.snapshot().contentIdentifier
                    == acquisition.contentIdentifier
            )
            #expect(
                request.snapshot().supportedProtocolVersions
                    == [3, 2, 1]
            )
            #expect(
                request.snapshot().deviceIdentifierPolicy
                    == .systemDefault
            )
            #expect(
                request.snapshot().processedKeys
                    == [Data("ckc".utf8)]
            )
            #expect(request.snapshot().failureCodes.isEmpty)
        }

        #expect(
            await transport.requests().map(\.purpose)
                == [.initial, .renewal]
        )
    }

    @Test("cached advisory keys bypass license transport and response submission")
    func reusesCachedAdvisoryKey() async throws {
        let transport = StreamingLicenseTransportDouble(
            response: Data("unused".utf8)
        )
        let workflow = HLSFairPlayStreamingKeyWorkflow(
            transport: transport,
            configuration: .safeDefaults(),
            advisoryKeyPolicy: .enabledForStreamingOnly
        )
        let request = StreamingKeyRequestDouble(
            spcResult: .fulfilledByAdvisoryKey
        )

        let event = try await workflow.fulfill(
            request,
            keyID: HLSFairPlayKeyID("cached-advisory-key"),
            acquisition: HLSFairPlayStreamingKeyAcquisition(
                applicationCertificate: Data("certificate".utf8),
                contentIdentifier: Data("content".utf8)
            ),
            purpose: .initial
        )

        #expect(event == .fulfilledByAdvisoryKey(.initial))
        #expect(await transport.requests().isEmpty)
        #expect(request.snapshot().processedKeys.isEmpty)
        #expect(request.snapshot().failureCodes.isEmpty)
    }

    @Test("invalid inputs fail before SPC or transport")
    func rejectsInvalidInputs() async throws {
        let keyID = try HLSFairPlayKeyID("invalid-streaming")
        let transport = StreamingLicenseTransportDouble(
            response: Data("unused".utf8)
        )
        let workflow = HLSFairPlayStreamingKeyWorkflow(
            transport: transport
        )
        var cases:
            [(
                HLSFairPlayStreamingKeyAcquisition,
                HLSFairPlayStreamingKeyError,
                Int
            )] = [
                (
                    HLSFairPlayStreamingKeyAcquisition(
                        applicationCertificate: Data(),
                        contentIdentifier: Data("content".utf8)
                    ),
                    .invalidApplicationCertificate,
                    11
                ),
                (
                    HLSFairPlayStreamingKeyAcquisition(
                        applicationCertificate: Data("certificate".utf8),
                        contentIdentifier: Data()
                    ),
                    .invalidContentIdentifier,
                    12
                ),
                (
                    HLSFairPlayStreamingKeyAcquisition(
                        applicationCertificate: Data("certificate".utf8),
                        contentIdentifier: Data("content".utf8),
                        supportedProtocolVersions: [3, 3]
                    ),
                    .invalidProtocolVersions,
                    22
                ),
                (
                    HLSFairPlayStreamingKeyAcquisition(
                        applicationCertificate: Data("certificate".utf8),
                        contentIdentifier: Data("content".utf8),
                        deviceIdentifierPolicy: .randomizedWithSeed(
                            Data(repeating: 1, count: 15)
                        )
                    ),
                    .invalidDeviceIdentifierSeed,
                    24
                ),
            ]
        if !HLSFairPlaySPCOptions.supportsDeviceIdentifierRandomization {
            cases.append(
                (
                    HLSFairPlayStreamingKeyAcquisition(
                        applicationCertificate: Data("certificate".utf8),
                        contentIdentifier: Data("content".utf8),
                        deviceIdentifierPolicy: .randomized
                    ),
                    .deviceIdentifierRandomizationUnavailable,
                    23
                )
            )
        }

        for (acquisition, expectedError, failureCode) in cases {
            let request = StreamingKeyRequestDouble()
            await #expect(throws: expectedError) {
                try await workflow.fulfill(
                    request,
                    keyID: keyID,
                    acquisition: acquisition,
                    purpose: .initial
                )
            }
            #expect(request.snapshot().applicationCertificate == nil)
            #expect(request.snapshot().failureCodes == [failureCode])
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test("SPC, transport, and CKC failures remain typed and terminal")
    func mapsWorkflowFailures() async throws {
        let keyID = try HLSFairPlayKeyID("workflow-failures")
        let acquisition = HLSFairPlayStreamingKeyAcquisition(
            applicationCertificate: Data("certificate".utf8),
            contentIdentifier: Data("content".utf8)
        )

        let spcRequest = StreamingKeyRequestDouble(spc: Data())
        await #expect(
            throws: HLSFairPlayStreamingKeyError.spcGenerationFailed
        ) {
            try await HLSFairPlayStreamingKeyWorkflow(
                transport: StreamingLicenseTransportDouble(
                    response: Data("unused".utf8)
                )
            ).fulfill(
                spcRequest,
                keyID: keyID,
                acquisition: acquisition,
                purpose: .initial
            )
        }
        #expect(spcRequest.snapshot().failureCodes == [17])

        let transportRequest = StreamingKeyRequestDouble()
        await #expect(
            throws: HLSFairPlayStreamingKeyError.licenseExchangeFailed
        ) {
            try await HLSFairPlayStreamingKeyWorkflow(
                transport: StreamingLicenseTransportDouble(
                    response: Data(),
                    failure: StreamingKeyTestError.failed
                )
            ).fulfill(
                transportRequest,
                keyID: keyID,
                acquisition: acquisition,
                purpose: .initial
            )
        }
        #expect(transportRequest.snapshot().failureCodes == [18])

        let responseRequest = StreamingKeyRequestDouble()
        await #expect(
            throws: HLSFairPlayStreamingKeyError.invalidLicenseResponse
        ) {
            try await HLSFairPlayStreamingKeyWorkflow(
                transport: StreamingLicenseTransportDouble(response: Data())
            ).fulfill(
                responseRequest,
                keyID: keyID,
                acquisition: acquisition,
                purpose: .renewal
            )
        }
        #expect(responseRequest.snapshot().processedKeys.isEmpty)
        #expect(responseRequest.snapshot().failureCodes == [19])
    }

    @Test("URL cancellation remains caller cancellation")
    func preservesCancellation() async throws {
        let request = StreamingKeyRequestDouble()
        let workflow = HLSFairPlayStreamingKeyWorkflow(
            transport: StreamingLicenseTransportDouble(
                response: Data(),
                failure: URLError(.cancelled)
            )
        )

        await #expect(throws: CancellationError.self) {
            try await workflow.fulfill(
                request,
                keyID: HLSFairPlayKeyID("cancelled-streaming"),
                acquisition: HLSFairPlayStreamingKeyAcquisition(
                    applicationCertificate: Data("certificate".utf8),
                    contentIdentifier: Data("content".utf8)
                ),
                purpose: .renewal
            )
        }

        #expect(request.snapshot().processedKeys.isEmpty)
        #expect(request.snapshot().failureCodes == [1])
    }

    @Test("retry and failure callbacks map to stable redacted events")
    func mapsLifecycleEvents() {
        #expect(
            HLSFairPlayContentKeyRetryReason(.timedOut) == .timedOut
        )
        #expect(
            HLSFairPlayContentKeyRetryReason(
                .receivedResponseWithExpiredLease
            ) == .expiredLease
        )
        #expect(
            HLSFairPlayContentKeyRetryReason(
                .receivedObsoleteContentKey
            ) == .obsoleteContentKey
        )
        #expect(
            HLSFairPlayContentKeyRetryReason(
                AVContentKeyRequest.RetryReason(
                    rawValue: "com.example.future-reason"
                )
            ) == .unknown
        )
        #expect(
            HLSFairPlayContentKeyFailureReason(
                URLError(.cancelled)
            ) == .cancelled
        )
        #expect(
            HLSFairPlayContentKeyFailureReason(
                URLError(.timedOut)
            ) == .timedOut
        )
        #expect(
            HLSFairPlayContentKeyFailureReason(
                NSError(
                    domain: AVFoundationErrorDomain,
                    code: AVError.Code.contentIsNotAuthorized.rawValue
                )
            ) == .notAuthorized
        )
        #expect(
            HLSFairPlayContentKeyFailureReason(
                NSError(
                    domain: AVFoundationErrorDomain,
                    code: AVError.Code.contentIsUnavailable.rawValue
                )
            ) == .contentUnavailable
        )
        #expect(
            HLSFairPlayContentKeyFailureReason(
                NSError(
                    domain: AVFoundationErrorDomain,
                    code: -11_860
                )
            ) == .requestCreationFailed
        )
        #expect(
            HLSFairPlayContentKeyFailureReason(
                NSError(
                    domain: AVFoundationErrorDomain,
                    code: -11_889
                )
            ) == .invalidResponse
        )
        #expect(
            HLSFairPlayContentKeyEvent.responseAccepted(.renewal)
                == .responseAccepted(.renewal)
        )
    }

    @Test("SPC callbacks prioritize errors over partial data")
    func validatesSPCCallback() throws {
        let data = Data("partial".utf8)

        #expect(throws: StreamingKeyTestError.failed) {
            try HLSFairPlayStreamingRequestAdapter.resolveSPC(
                data: data,
                error: StreamingKeyTestError.failed,
                canBeFulfilledWithAdvisoryKey: true
            )
        }
        #expect(
            throws: HLSFairPlayStreamingKeyError.spcGenerationFailed
        ) {
            try HLSFairPlayStreamingRequestAdapter.resolveSPC(
                data: nil,
                error: nil,
                canBeFulfilledWithAdvisoryKey: false
            )
        }
        #expect(
            try HLSFairPlayStreamingRequestAdapter.resolveSPC(
                data: data,
                error: nil,
                canBeFulfilledWithAdvisoryKey: true
            ) == .generated(data)
        )
        #expect(
            try HLSFairPlayStreamingRequestAdapter.resolveSPC(
                data: nil,
                error: nil,
                canBeFulfilledWithAdvisoryKey: true
            ) == .fulfilledByAdvisoryKey
        )
    }

    @Test("streaming-key failures provide actionable localization")
    func diagnostics() {
        let error =
            HLSFairPlayStreamingKeyError.invalidProtocolVersions
        #expect(!error.localizedDescription.isEmpty)
        #expect(error.recoverySuggestion?.contains("16") == true)

        let seedError =
            HLSFairPlayStreamingKeyError.invalidDeviceIdentifierSeed
        #expect(seedError.localizedDescription.contains("16"))
        #expect(seedError.recoverySuggestion?.contains("16") == true)
    }
}

private enum StreamingKeyTestError: Error {
    case failed
}

private final class StreamingKeyRequestDouble:
    HLSFairPlayStreamingRequestHandling,
    @unchecked Sendable
{
    struct Snapshot {
        let applicationCertificate: Data?
        let contentIdentifier: Data?
        let supportedProtocolVersions: [Int]?
        let deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy?
        let processedKeys: [Data]
        let failureCodes: [Int]
    }

    private let lock = NSLock()
    private let spcResult: HLSFairPlayStreamingSPCResult
    private var applicationCertificate: Data?
    private var contentIdentifier: Data?
    private var supportedProtocolVersions: [Int]?
    private var deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy?
    private var processedKeys: [Data] = []
    private var failureCodes: [Int] = []

    init(spc: Data = Data("spc".utf8)) {
        self.spcResult = .generated(spc)
    }

    init(spcResult: HLSFairPlayStreamingSPCResult) {
        self.spcResult = spcResult
    }

    func makeSPC(
        applicationCertificate: Data,
        contentIdentifier: Data,
        supportedProtocolVersions: [Int],
        deviceIdentifierPolicy: HLSFairPlayDeviceIdentifierPolicy
    ) async throws -> HLSFairPlayStreamingSPCResult {
        lock.withLock {
            self.applicationCertificate = applicationCertificate
            self.contentIdentifier = contentIdentifier
            self.supportedProtocolVersions = supportedProtocolVersions
            self.deviceIdentifierPolicy = deviceIdentifierPolicy
        }
        return spcResult
    }

    func processStreamingKey(_ data: Data) {
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
                supportedProtocolVersions: supportedProtocolVersions,
                deviceIdentifierPolicy: deviceIdentifierPolicy,
                processedKeys: processedKeys,
                failureCodes: failureCodes
            )
        }
    }
}

private actor StreamingLicenseTransportDouble:
    HLSFairPlayLicenseTransporting
{
    private let response: Data
    private let failure: (any Error)?
    private var capturedRequests: [HLSFairPlayLicenseRequest] = []

    init(response: Data, failure: (any Error)? = nil) {
        self.response = response
        self.failure = failure
    }

    func contentKeyContext(
        for request: HLSFairPlayLicenseRequest
    ) async throws -> Data {
        capturedRequests.append(request)
        if let failure {
            throw failure
        }
        return response
    }

    func requests() -> [HLSFairPlayLicenseRequest] {
        capturedRequests
    }
}
#endif
