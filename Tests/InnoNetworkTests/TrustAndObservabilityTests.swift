import Foundation
import Security
import Testing
@testable import InnoNetwork

private struct TrustObservabilityRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var method: HTTPMethod { .get }
    var path: String { "/status" }
}


private struct TrustObservabilityRetryPolicy: RetryPolicy {
    let maxRetries: Int = 1
    let maxTotalRetries: Int = 1
    let retryDelay: TimeInterval = 0

    func retryDelay(for retryIndex: Int) -> TimeInterval {
        _ = retryIndex
        return retryDelay
    }

    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        guard retryIndex < maxRetries else { return false }
        switch error {
        case .underlying, .nonHTTPResponse:
            return true
        default:
            return false
        }
    }
}


private actor FlakyContextSession: URLSessionProtocol {
    private var failuresBeforeSuccess: Int
    private var capturedContexts: [NetworkRequestContext] = []

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await data(for: request, context: NetworkRequestContext())
    }

    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        capturedContexts.append(context)
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw URLError(.timedOut)
        }

        let url = request.url ?? URL(string: "https://api.example.com/v2/status")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(#""ok""#.utf8), response)
    }

    func allCapturedContexts() -> [NetworkRequestContext] {
        capturedContexts
    }
}


private actor NetworkEventStore {
    private var events: [NetworkEvent] = []

    func append(_ event: NetworkEvent) {
        events.append(event)
    }

    func snapshot() -> [NetworkEvent] {
        events
    }
}


private struct RecordingNetworkEventObserver: NetworkEventObserving {
    let store: NetworkEventStore

    func handle(_ event: NetworkEvent) async {
        await store.append(event)
    }
}


private final class SlowNetworkEventObserver: NetworkEventObserving, Sendable {
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func handle(_ event: NetworkEvent) async {
        _ = event
        try? await Task.sleep(for: .seconds(delay))
    }
}


private struct AcceptingTrustEvaluator: TrustEvaluating {
    func evaluate(challenge: URLAuthenticationChallenge) -> Bool {
        _ = challenge
        return true
    }
}


private struct RejectingTrustEvaluator: TrustEvaluating {
    func evaluate(challenge: URLAuthenticationChallenge) -> Bool {
        _ = challenge
        return false
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}


@Suite("Trust and Observability Tests", .serialized)
struct TrustAndObservabilityTests {
    @Test("Public key pinning policy matches subdomains and exact hosts")
    func pinningPolicyHostMatching() {
        let policy = PublicKeyPinningPolicy(
            pinsByHost: [
                "api.example.com": ["sha256/primary-pin"],
                "example.com": ["sha256/backup-pin"]
            ],
            includesSubdomains: true
        )

        let exactHostPins = policy.pins(forHost: "api.example.com")
        #expect(exactHostPins == Set(["sha256/primary-pin", "sha256/backup-pin"]))

        let subdomainPins = policy.pins(forHost: "mobile.api.example.com")
        #expect(subdomainPins == Set(["sha256/primary-pin", "sha256/backup-pin"]))

        #expect(policy.pins(forHost: "unrelated.domain") == nil)
    }

    @Test("Public key pinning rejects unsupported authentication method")
    func unsupportedAuthMethodRejected() {
        let challenge = makeChallenge(
            host: "api.example.com",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let policy = TrustPolicy.publicKeyPinning(
            PublicKeyPinningPolicy(
                pinsByHost: ["api.example.com": ["sha256/primary-pin"]],
                allowDefaultEvaluationForUnpinnedHosts: false
            )
        )

        let result = TrustEvaluator.evaluate(challenge: challenge, policy: policy)
        switch result {
        case .cancel(.unsupportedAuthenticationMethod(let method)):
            #expect(method == NSURLAuthenticationMethodHTTPBasic)
        default:
            Issue.record("Expected unsupported authentication method to be rejected.")
        }
    }

    @Test("Custom trust evaluator can reject or accept challenge")
    func customTrustEvaluatorPath() {
        let challenge = makeChallenge(
            host: "api.example.com",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )

        let rejected = TrustEvaluator.evaluate(
            challenge: challenge,
            policy: .custom(RejectingTrustEvaluator())
        )
        switch rejected {
        case .cancel(.custom(let message)):
            #expect(message.contains("rejected"))
        default:
            Issue.record("Expected custom evaluator rejection to cancel trust evaluation.")
        }

        let accepted = TrustEvaluator.evaluate(
            challenge: challenge,
            policy: .custom(AcceptingTrustEvaluator())
        )
        switch accepted {
        case .performDefaultHandling:
            #expect(Bool(true))
        default:
            Issue.record("Expected custom evaluator acceptance to continue with default handling when trust is unavailable.")
        }
    }

    @Test("Network lifecycle events include retry chain with same correlation id")
    func lifecycleEventsWithRetry() async throws {
        let session = FlakyContextSession(failuresBeforeSuccess: 1)
        let store = NetworkEventStore()
        let observer = RecordingNetworkEventObserver(store: store)
        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v2")!,
            retryPolicy: TrustObservabilityRetryPolicy(),
            networkMonitor: nil,
            metricsReporter: nil,
            trustPolicy: .systemDefault,
            eventObservers: [observer]
        )
        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: session
        )

        let value = try await client.request(TrustObservabilityRequest())
        #expect(value == "ok")

        let events = await waitForEvents(store: store, minimumCount: 8)
        #expect(events.count >= 8)

        let requestIDs = Set(events.map(requestID(of:)))
        #expect(requestIDs.count == 1)

        let startRetryIndexes = events.compactMap { event -> Int? in
            guard case .requestStart(_, _, _, let retryIndex) = event else { return nil }
            return retryIndex
        }
        #expect(startRetryIndexes == [0, 1])

        let adaptedRetryIndexes = events.compactMap { event -> Int? in
            guard case .requestAdapted(_, _, _, let retryIndex) = event else { return nil }
            return retryIndex
        }
        #expect(adaptedRetryIndexes == [0, 1])

        let retryScheduledIndexes = events.compactMap { event -> Int? in
            guard case .retryScheduled(_, let retryIndex, _, _) = event else { return nil }
            return retryIndex
        }
        #expect(retryScheduledIndexes == [0])

        let responseCount = events.filter { event in
            if case .responseReceived = event { return true }
            return false
        }.count
        #expect(responseCount == 1)

        let failedCount = events.filter { event in
            if case .requestFailed = event { return true }
            return false
        }.count
        #expect(failedCount == 1)

        let finishedCount = events.filter { event in
            if case .requestFinished = event { return true }
            return false
        }.count
        #expect(finishedCount == 1)
    }

    @Test("Network request context forwards trust policy and retry index")
    func requestContextForwarding() async throws {
        let session = FlakyContextSession(failuresBeforeSuccess: 0)
        let trustPolicy = TrustPolicy.publicKeyPinning(
            PublicKeyPinningPolicy(
                pinsByHost: ["api.example.com": ["sha256/primary-pin", "sha256/backup-pin"]],
                includesSubdomains: false,
                allowDefaultEvaluationForUnpinnedHosts: false
            )
        )
        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v2")!,
            retryPolicy: nil,
            networkMonitor: nil,
            metricsReporter: nil,
            trustPolicy: trustPolicy,
            eventObservers: []
        )
        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: session
        )

        let value = try await client.request(TrustObservabilityRequest())
        #expect(value == "ok")

        let contexts = await session.allCapturedContexts()
        let forwardedContext = try #require(contexts.first)
        #expect(forwardedContext.retryIndex == 0)

        switch forwardedContext.trustPolicy {
        case .publicKeyPinning(let policy):
            #expect(policy.pinsByHost["api.example.com"] == Set(["sha256/primary-pin", "sha256/backup-pin"]))
            #expect(policy.includesSubdomains == false)
            #expect(policy.allowDefaultEvaluationForUnpinnedHosts == false)
        default:
            Issue.record("Expected forwarded trust policy to be public key pinning.")
        }
    }

    @Test("Slow observers do not block request completion path")
    func slowObserverNonBlocking() async throws {
        let session = FlakyContextSession(failuresBeforeSuccess: 0)
        let slowObserver = SlowNetworkEventObserver(delay: 0.2)
        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v2")!,
            retryPolicy: nil,
            networkMonitor: nil,
            metricsReporter: nil,
            trustPolicy: .systemDefault,
            eventObservers: [slowObserver]
        )
        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: session
        )

        let start = Date()
        let value = try await client.request(TrustObservabilityRequest())
        let elapsed = Date().timeIntervalSince(start)

        #expect(value == "ok")
        #expect(elapsed < 0.75)
    }

    @Test("SPKI helper supports common key types")
    func spkiEncodingHelperSupportsCommonKeyTypes() {
        let keyData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let rsa = TrustEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: kSecAttrKeyTypeRSA as String,
            keySizeInBits: 2048
        )
        #expect(rsa != nil)
        #expect((rsa?.count ?? 0) > keyData.count)

        let p256 = TrustEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: kSecAttrKeyTypeECSECPrimeRandom as String,
            keySizeInBits: 256
        )
        #expect(p256 != nil)
        #expect((p256?.count ?? 0) > keyData.count)

        let unsupported = TrustEvaluator.spkiData(
            publicKeyData: keyData,
            keyType: "com.innonetwork.unsupported",
            keySizeInBits: 0
        )
        #expect(unsupported == nil)
    }

    private func waitForEvents(
        store: NetworkEventStore,
        minimumCount: Int,
        timeout: TimeInterval = 1.0
    ) async -> [NetworkEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = await store.snapshot()
            if events.count >= minimumCount {
                return events
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await store.snapshot()
    }

    private func requestID(of event: NetworkEvent) -> UUID {
        switch event {
        case .requestStart(let requestID, _, _, _):
            return requestID
        case .requestAdapted(let requestID, _, _, _):
            return requestID
        case .responseReceived(let requestID, _, _):
            return requestID
        case .retryScheduled(let requestID, _, _, _):
            return requestID
        case .requestFinished(let requestID, _, _):
            return requestID
        case .requestFailed(let requestID, _, _):
            return requestID
        }
    }

    private func makeChallenge(
        host: String,
        authenticationMethod: String
    ) -> URLAuthenticationChallenge {
        let sender = ChallengeSender()
        let protectionSpace = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: authenticationMethod
        )
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
    }
}
