#if canImport(AVFoundation) && (os(iOS) || os(macOS))
import AVFoundation
import Foundation
import Testing
import os

import InnoNetworkHLSAVFoundation

@Suite("FairPlay physical-device acceptance", .serialized)
struct HLSFairPlayAcceptanceRuntimeTests {
    @Test("protocol versions fail closed on malformed input")
    func protocolVersionsFailClosed() throws {
        #expect(
            try FairPlayAcceptanceConfiguration.parseProtocolVersions(
                "3,2,1"
            ) == [3, 2, 1]
        )
        for rawValue in ["", "3,,2", "3,unknown", "3,3", "0,3"] {
            #expect(throws: FairPlayAcceptanceError.self) {
                try FairPlayAcceptanceConfiguration.parseProtocolVersions(
                    rawValue
                )
            }
        }
    }

    @MainActor
    @Test(
        "SPC v3 initial and renewal responses are accepted",
        .timeLimit(.minutes(5))
    )
    func streamingKeyAndRenewalAreAccepted() async throws {
        guard Self.isPhysicalIOS else {
            try Test.cancel()
        }
        guard
            let configuration = try FairPlayAcceptanceConfiguration.load(
                requiresAsset: false
            )
        else {
            try Test.cancel()
        }

        let client = FairPlayAcceptanceHTTPSClient(
            timeout: configuration.timeout
        )
        let certificate = try await client.data(
            from: configuration.certificateURL,
            maximumBytes: configuration.maximumMaterialBytes
        )
        let transport = FairPlayAcceptanceLicenseTransport(
            client: client,
            configuration: configuration
        )
        let recorder = FairPlayAcceptanceEventRecorder()
        let delegate = FairPlayStreamingAcceptanceDelegate(
            workflow: HLSFairPlayStreamingKeyWorkflow(
                transport: transport
            ),
            keyID: configuration.keyID,
            acquisition: configuration.streamingAcquisition(
                certificate: certificate
            ),
            recorder: recorder
        )
        let session = try HLSFairPlaySession(
            delegate: delegate,
            delegateQueue: DispatchQueue(
                label: "com.innonetwork.tests.fairplay.acceptance.streaming"
            )
        )
        defer {
            session.expire()
        }

        session.contentKeySession.processContentKeyRequest(
            withIdentifier: configuration.requestIdentifier,
            initializationData: nil,
            options: nil
        )
        try await recorder.waitForAcceptance(
            purpose: .initial,
            timeout: configuration.timeout
        )

        let initialRequest = try #require(delegate.initialRequest())
        session.contentKeySession
            .renewExpiringResponseData(for: initialRequest)
        try await recorder.waitForAcceptance(
            purpose: .renewal,
            timeout: configuration.timeout
        )

        #expect(
            await transport.requestPurposes()
                == [.initial, .renewal]
        )
    }

    @MainActor
    @Test(
        "downloaded persistent-key asset survives session recreation",
        .timeLimit(.minutes(15))
    )
    func downloadedAssetReopensWithoutLicenseTransport() async throws {
        guard Self.isPhysicalIOS else {
            try Test.cancel()
        }
        guard
            let configuration = try FairPlayAcceptanceConfiguration.load(
                requiresAsset: true
            )
        else {
            try Test.cancel()
        }
        let sourceURL = try #require(configuration.assetURL)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "innonetwork-fairplay-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let client = FairPlayAcceptanceHTTPSClient(
            timeout: configuration.timeout
        )
        let certificate = try await client.data(
            from: configuration.certificateURL,
            maximumBytes: configuration.maximumMaterialBytes
        )
        let transport = FairPlayAcceptanceLicenseTransport(
            client: client,
            configuration: configuration
        )
        let keyURL = rootURL.appendingPathComponent("persistent-key")
        let initialStore = FairPlayAcceptanceFileKeyStore(
            keyURL: keyURL
        )
        let initialRecorder = FairPlayPersistenceRecorder()
        let initialDelegate = FairPlayPersistenceAcceptanceDelegate(
            workflow: HLSFairPlayPersistentKeyWorkflow(
                transport: transport,
                storage: initialStore
            ),
            keyID: configuration.keyID,
            acquisition: configuration.persistentAcquisition(
                certificate: certificate
            ),
            recorder: initialRecorder
        )
        let initialSession = try HLSFairPlaySession(
            delegate: initialDelegate,
            delegateQueue: DispatchQueue(
                label: "com.innonetwork.tests.fairplay.acceptance.download"
            )
        )
        let remoteAsset = try initialSession.makeAsset(
            sourceURL: sourceURL
        )
        let downloadSession = try HLSAssetDownloadSession(
            configuration: HLSAssetDownloadSessionPack(
                identifier:
                    "com.innonetwork.tests.fairplay.acceptance."
                    + UUID().uuidString
            )
        )
        let download = try downloadSession.start(
            asset: remoteAsset,
            title: "InnoNetwork FairPlay acceptance"
        )
        let packageURL = try await Self.completedLocation(
            events: downloadSession.events(for: download)
        )
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        try await initialRecorder.waitForDisposition(
            .created,
            timeout: configuration.timeout
        )
        await downloadSession.shutdown()
        try initialSession.detach(remoteAsset)
        initialSession.expire()

        let storedAsset = try HLSStoredAsset(
            id: "fairplay-acceptance-offline",
            location: packageURL
        )
        let readiness = try await HLSOfflineAssetInspector().inspect(
            storedAsset
        )
        #expect(readiness.state == .ready)
        #expect(readiness.isPlayableOffline)

        let offlineTransport = FairPlayRejectingLicenseTransport()
        let reopenedStore = FairPlayAcceptanceFileKeyStore(
            keyURL: keyURL
        )
        let reopenedRecorder = FairPlayPersistenceRecorder()
        let reopenedDelegate = FairPlayPersistenceAcceptanceDelegate(
            workflow: HLSFairPlayPersistentKeyWorkflow(
                transport: offlineTransport,
                storage: reopenedStore
            ),
            keyID: configuration.keyID,
            acquisition: nil,
            recorder: reopenedRecorder
        )
        let reopenedSession = try HLSFairPlaySession(
            delegate: reopenedDelegate,
            delegateQueue: DispatchQueue(
                label: "com.innonetwork.tests.fairplay.acceptance.reopen"
            )
        )
        defer {
            reopenedSession.expire()
        }
        let offlineAsset = try reopenedSession.makeAsset(
            storedAsset: storedAsset
        )
        let playerItem = AVPlayerItem(asset: offlineAsset)
        let player = AVPlayer(playerItem: playerItem)
        defer {
            player.pause()
            try? reopenedSession.detach(offlineAsset)
        }

        player.play()
        try await Self.waitForPlaybackAdvance(
            player: player,
            item: playerItem,
            timeout: configuration.timeout
        )
        try await reopenedRecorder.waitForDisposition(
            .restored,
            timeout: configuration.timeout
        )

        #expect(await offlineTransport.requestCount() == 0)
    }

    private static func completedLocation(
        events: AsyncStream<HLSAssetDownloadEvent>
    ) async throws -> URL {
        for await event in events {
            switch event {
            case .completed(let location):
                return location
            case .failed:
                throw FairPlayAcceptanceError.downloadFailed
            case .cancelled:
                throw CancellationError()
            case .variantSelection, .progress, .downloadSummary,
                .locationAvailable:
                continue
            }
        }
        throw FairPlayAcceptanceError.downloadFailed
    }

    private static var isPhysicalIOS: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    @MainActor
    private static func waitForPlaybackAdvance(
        player: AVPlayer,
        item: AVPlayerItem,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if item.status == .failed {
                throw FairPlayAcceptanceError.playbackFailed
            }
            if item.status == .readyToPlay,
                player.currentTime().seconds.isFinite,
                player.currentTime().seconds >= 0.25
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FairPlayAcceptanceError.timedOut
    }
}

private struct FairPlayAcceptanceConfiguration: Sendable {
    private static let commonNames = [
        "INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL",
        "INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64",
        "INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID",
        "INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL",
        "INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER",
    ]

    let certificateURL: URL
    let contentIdentifier: Data
    let keyID: HLSFairPlayKeyID
    let ksmURL: URL
    let requestIdentifier: URL
    let assetURL: URL?
    let authorization: String?
    let protocolVersions: [Int]
    let timeout: Duration
    let maximumMaterialBytes = 1 * 1_024 * 1_024

    static func load(
        requiresAsset: Bool
    ) throws -> FairPlayAcceptanceConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let requiredNames =
            commonNames
            + (requiresAsset
                ? ["INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL"] : [])
        let presentNames = requiredNames.filter {
            environment[$0]?.isEmpty == false
        }
        if presentNames.isEmpty {
            return nil
        }
        let missingNames = requiredNames.filter {
            environment[$0]?.isEmpty != false
        }
        guard missingNames.isEmpty else {
            throw FairPlayAcceptanceError.incompleteConfiguration(
                missingNames.sorted()
            )
        }

        let certificateURL = try httpsURL(
            environment[
                "INNONETWORK_FAIRPLAY_ACCEPTANCE_CERTIFICATE_URL"
            ]
        )
        guard
            let encodedContentIdentifier = environment[
                "INNONETWORK_FAIRPLAY_ACCEPTANCE_CONTENT_IDENTIFIER_BASE64"
            ],
            let contentIdentifier = Data(
                base64Encoded: encodedContentIdentifier
            ),
            !contentIdentifier.isEmpty
        else {
            throw FairPlayAcceptanceError.invalidConfiguration
        }
        let keyID = try HLSFairPlayKeyID(
            try required(
                "INNONETWORK_FAIRPLAY_ACCEPTANCE_KEY_ID",
                environment: environment
            )
        )
        let ksmURL = try httpsURL(
            environment["INNONETWORK_FAIRPLAY_ACCEPTANCE_KSM_URL"]
        )
        guard
            let requestIdentifier = URL(
                string: try required(
                    "INNONETWORK_FAIRPLAY_ACCEPTANCE_REQUEST_IDENTIFIER",
                    environment: environment
                )
            ),
            requestIdentifier.scheme?.isEmpty == false
        else {
            throw FairPlayAcceptanceError.invalidConfiguration
        }
        let assetURL: URL?
        if requiresAsset {
            assetURL = try httpsURL(
                environment[
                    "INNONETWORK_FAIRPLAY_ACCEPTANCE_ASSET_URL"
                ]
            )
        } else {
            assetURL = nil
        }
        let protocolVersions = try parseProtocolVersions(
            environment[
                "INNONETWORK_FAIRPLAY_ACCEPTANCE_PROTOCOL_VERSIONS"
            ] ?? "3"
        )
        guard protocolVersions.contains(3) else {
            throw FairPlayAcceptanceError.spcVersion3Required
        }
        let timeoutSeconds =
            Int(
                environment["INNONETWORK_FAIRPLAY_ACCEPTANCE_TIMEOUT_SECONDS"]
                    ?? "60"
            ) ?? 60

        return FairPlayAcceptanceConfiguration(
            certificateURL: certificateURL,
            contentIdentifier: contentIdentifier,
            keyID: keyID,
            ksmURL: ksmURL,
            requestIdentifier: requestIdentifier,
            assetURL: assetURL,
            authorization: environment[
                "INNONETWORK_FAIRPLAY_ACCEPTANCE_AUTHORIZATION"
            ],
            protocolVersions: protocolVersions,
            timeout: .seconds(min(300, max(5, timeoutSeconds)))
        )
    }

    func streamingAcquisition(
        certificate: Data
    ) -> HLSFairPlayStreamingKeyAcquisition {
        HLSFairPlayStreamingKeyAcquisition(
            applicationCertificate: certificate,
            contentIdentifier: contentIdentifier,
            supportedProtocolVersions: protocolVersions
        )
    }

    func persistentAcquisition(
        certificate: Data
    ) -> HLSFairPlayPersistentKeyAcquisition {
        HLSFairPlayPersistentKeyAcquisition(
            applicationCertificate: certificate,
            contentIdentifier: contentIdentifier,
            supportedProtocolVersions: protocolVersions
        )
    }

    private static func required(
        _ name: String,
        environment: [String: String]
    ) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw FairPlayAcceptanceError.incompleteConfiguration([name])
        }
        return value
    }

    private static func httpsURL(_ value: String?) throws -> URL {
        guard
            let value,
            let url = URL(string: value),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false,
            url.user == nil,
            url.password == nil
        else {
            throw FairPlayAcceptanceError.invalidConfiguration
        }
        return url
    }

    fileprivate static func parseProtocolVersions(
        _ rawValue: String
    ) throws -> [Int] {
        let components = rawValue.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty, components.count <= 16 else {
            throw FairPlayAcceptanceError.invalidConfiguration
        }
        var versions: [Int] = []
        versions.reserveCapacity(components.count)
        for component in components {
            let value = component.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, let version = Int(value), version > 0 else {
                throw FairPlayAcceptanceError.invalidConfiguration
            }
            versions.append(version)
        }
        guard
            Set(versions).count == versions.count
        else {
            throw FairPlayAcceptanceError.invalidConfiguration
        }
        return versions
    }
}

private actor FairPlayAcceptanceHTTPSClient {
    private let redirectDelegate: FairPlayAcceptanceNoRedirectDelegate
    private let session: URLSession

    init(timeout: Duration) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = timeout.timeInterval
        configuration.timeoutIntervalForResource = timeout.timeInterval
        let redirectDelegate = FairPlayAcceptanceNoRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func data(
        from url: URL,
        maximumBytes: Int,
        authorization: String? = nil,
        body: Data? = nil,
        purpose: HLSFairPlayLicenseRequestPurpose? = nil,
        keyID: HLSFairPlayKeyID? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        if body != nil {
            request.setValue(
                "application/octet-stream",
                forHTTPHeaderField: "Content-Type"
            )
        }
        if let authorization, !authorization.isEmpty {
            request.setValue(
                authorization,
                forHTTPHeaderField: "Authorization"
            )
        }
        if let purpose {
            request.setValue(
                purpose == .initial ? "initial" : "renewal",
                forHTTPHeaderField:
                    "X-InnoNetwork-FairPlay-Request-Purpose"
            )
        }
        if let keyID {
            request.setValue(
                keyID.rawValue,
                forHTTPHeaderField: "X-InnoNetwork-FairPlay-Key-ID"
            )
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            httpResponse.url?.scheme?.lowercased() == "https"
        else {
            throw FairPlayAcceptanceError.transportFailed
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw FairPlayAcceptanceError.responseTooLarge
            }
            data.append(byte)
        }
        guard !data.isEmpty else {
            throw FairPlayAcceptanceError.transportFailed
        }
        return data
    }
}

private final class FairPlayAcceptanceNoRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor FairPlayAcceptanceLicenseTransport:
    HLSFairPlayLicenseTransporting
{
    private let client: FairPlayAcceptanceHTTPSClient
    private let configuration: FairPlayAcceptanceConfiguration
    private var purposes: [HLSFairPlayLicenseRequestPurpose] = []

    init(
        client: FairPlayAcceptanceHTTPSClient,
        configuration: FairPlayAcceptanceConfiguration
    ) {
        self.client = client
        self.configuration = configuration
    }

    func contentKeyContext(
        for request: HLSFairPlayLicenseRequest
    ) async throws -> Data {
        purposes.append(request.purpose)
        return try await client.data(
            from: configuration.ksmURL,
            maximumBytes: configuration.maximumMaterialBytes,
            authorization: configuration.authorization,
            body: request.spcData,
            purpose: request.purpose,
            keyID: request.keyID
        )
    }

    func requestPurposes() -> [HLSFairPlayLicenseRequestPurpose] {
        purposes
    }
}

private final class FairPlayStreamingAcceptanceDelegate:
    NSObject,
    AVContentKeySessionDelegate,
    @unchecked Sendable
{
    private struct State {
        var purposes: [ObjectIdentifier: HLSFairPlayLicenseRequestPurpose] =
            [:]
        var initialRequest: AVContentKeyRequest?
    }

    private let workflow: HLSFairPlayStreamingKeyWorkflow
    private let keyID: HLSFairPlayKeyID
    private let acquisition: HLSFairPlayStreamingKeyAcquisition
    private let recorder: FairPlayAcceptanceEventRecorder
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        workflow: HLSFairPlayStreamingKeyWorkflow,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayStreamingKeyAcquisition,
        recorder: FairPlayAcceptanceEventRecorder
    ) {
        self.workflow = workflow
        self.keyID = keyID
        self.acquisition = acquisition
        self.recorder = recorder
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVContentKeyRequest
    ) {
        state.withLock { state in
            state.initialRequest = keyRequest
            state.purposes[ObjectIdentifier(keyRequest)] = .initial
        }
        fulfill(keyRequest, purpose: .initial)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
    ) {
        state.withLock {
            $0.purposes[ObjectIdentifier(keyRequest)] = .renewal
        }
        fulfill(keyRequest, purpose: .renewal)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest
    ) {
        guard
            let purpose = state.withLock({
                $0.purposes.removeValue(
                    forKey: ObjectIdentifier(keyRequest)
                )
            })
        else {
            return
        }
        Task {
            await recorder.record(.responseAccepted(purpose))
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError error: any Error
    ) {
        Task {
            await recorder.record(
                .failed(HLSFairPlayContentKeyFailureReason(error))
            )
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        Task {
            await recorder.record(
                .retryRequested(
                    HLSFairPlayContentKeyRetryReason(retryReason)
                )
            )
        }
        return false
    }

    func initialRequest() -> AVContentKeyRequest? {
        state.withLock(\.initialRequest)
    }

    private func fulfill(
        _ request: AVContentKeyRequest,
        purpose: HLSFairPlayLicenseRequestPurpose
    ) {
        Task {
            do {
                let event = try await workflow.fulfill(
                    request,
                    keyID: keyID,
                    acquisition: acquisition,
                    purpose: purpose
                )
                await recorder.record(event)
            } catch {
                await recorder.record(
                    .failed(HLSFairPlayContentKeyFailureReason(error))
                )
            }
        }
    }
}

private actor FairPlayAcceptanceEventRecorder {
    private var events: [HLSFairPlayContentKeyEvent] = []

    func record(_ event: HLSFairPlayContentKeyEvent) {
        events.append(event)
    }

    func waitForAcceptance(
        purpose: HLSFairPlayLicenseRequestPurpose,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if events.contains(.responseAccepted(purpose)) {
                return
            }
            if events.contains(where: {
                if case .failed = $0 { true } else { false }
            }) {
                throw FairPlayAcceptanceError.keyRequestFailed
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FairPlayAcceptanceError.timedOut
    }
}

private final class FairPlayPersistenceAcceptanceDelegate:
    NSObject,
    AVContentKeySessionDelegate,
    @unchecked Sendable
{
    private let workflow: HLSFairPlayPersistentKeyWorkflow
    private let keyID: HLSFairPlayKeyID
    private let acquisition: HLSFairPlayPersistentKeyAcquisition?
    private let recorder: FairPlayPersistenceRecorder

    init(
        workflow: HLSFairPlayPersistentKeyWorkflow,
        keyID: HLSFairPlayKeyID,
        acquisition: HLSFairPlayPersistentKeyAcquisition?,
        recorder: FairPlayPersistenceRecorder
    ) {
        self.workflow = workflow
        self.keyID = keyID
        self.acquisition = acquisition
        self.recorder = recorder
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVContentKeyRequest
    ) {
        do {
            try workflow.requestPersistence(for: keyRequest)
        } catch {
            keyRequest.processContentKeyResponseError(error as NSError)
            Task {
                await recorder.recordFailure()
            }
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVPersistableContentKeyRequest
    ) {
        Task {
            do {
                let disposition = try await workflow.fulfill(
                    keyRequest,
                    keyID: keyID,
                    acquisition: acquisition
                )
                await recorder.record(disposition)
            } catch {
                await recorder.recordFailure()
            }
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didUpdatePersistableContentKey persistableContentKey: Data,
        forContentKeyIdentifier keyIdentifier: Any
    ) {
        Task {
            do {
                try await workflow.storeUpdatedPersistableContentKey(
                    persistableContentKey,
                    for: keyID
                )
            } catch {
                await recorder.recordFailure()
            }
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError error: any Error
    ) {
        Task {
            await recorder.recordFailure()
        }
    }
}

private actor FairPlayPersistenceRecorder {
    private var dispositions: [HLSFairPlayPersistentKeyDisposition] = []
    private var didFail = false

    func record(_ disposition: HLSFairPlayPersistentKeyDisposition) {
        dispositions.append(disposition)
    }

    func recordFailure() {
        didFail = true
    }

    func waitForDisposition(
        _ disposition: HLSFairPlayPersistentKeyDisposition,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if dispositions.contains(disposition) {
                return
            }
            if didFail {
                throw FairPlayAcceptanceError.keyRequestFailed
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FairPlayAcceptanceError.timedOut
    }
}

private actor FairPlayAcceptanceFileKeyStore:
    HLSFairPlayPersistentKeyStoring
{
    private let keyURL: URL

    init(keyURL: URL) {
        self.keyURL = keyURL
    }

    func persistableContentKey(
        for keyID: HLSFairPlayKeyID
    ) async throws -> Data? {
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            return nil
        }
        return try Data(
            contentsOf: keyURL,
            options: [.mappedIfSafe]
        )
    }

    func storePersistableContentKey(
        _ data: Data,
        for keyID: HLSFairPlayKeyID
    ) async throws {
        try data.write(to: keyURL, options: [.atomic])
    }
}

private actor FairPlayRejectingLicenseTransport:
    HLSFairPlayLicenseTransporting
{
    private var count = 0

    func contentKeyContext(
        for request: HLSFairPlayLicenseRequest
    ) async throws -> Data {
        count += 1
        throw FairPlayAcceptanceError.offlineLicenseRequest
    }

    func requestCount() -> Int {
        count
    }
}

private enum FairPlayAcceptanceError: Error, Sendable {
    case incompleteConfiguration([String])
    case invalidConfiguration
    case spcVersion3Required
    case transportFailed
    case responseTooLarge
    case keyRequestFailed
    case downloadFailed
    case playbackFailed
    case offlineLicenseRequest
    case timedOut
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
#endif
