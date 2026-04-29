import Foundation
import Testing

@testable import InnoNetwork

@Suite("Observability Lifecycle Tests", .serialized)
struct ObservabilityLifecycleTests {

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

        let events = await waitForTrustObservabilityEvents(store: store, minimumCount: 8)
        #expect(events.count >= 8)

        let requestIDs = Set(events.map(trustObservabilityRequestID(of:)))
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
}
