import Foundation
import Testing

@testable import InnoNetwork

@Suite("Coalesced response limit isolation", .timeLimit(.minutes(1)))
struct CoalescedResponseLimitTests {
    @Test(arguments: [true, false])
    func mixedLimitsAreIndependent(strictFirst: Bool) async throws {
        let session = LimitHeldSession()
        let client = makeClient(session)
        let first: Int64 = strictFirst ? 1 : 100
        let second: Int64 = strictFirst ? 100 : 1
        let leader = Task { await result(client, limit: first) }
        await session.waitForEntries(1)
        let follower = Task { await result(client, limit: second) }
        await client.waitForCoalescedCallerCount(atLeast: 2)
        // Waiter admission occurs before the physical task is scheduled.
        // Keep the gate open for any transport that starts after release.
        await session.release()
        #expect(await leader.value == (first >= 10))
        #expect(await follower.value == (second >= 10))
        #expect(await session.count == 2)
    }

    @Test func equalEffectiveLimitsStillShareOneTransport() async {
        let session = LimitHeldSession()
        let client = makeClient(session)
        let leader = Task { await result(client, limit: 100) }
        await session.waitForEntries(1)
        let follower = Task { await result(client, limit: 100) }
        await client.waitForCoalescedCallerCount(atLeast: 2)
        await session.release()
        #expect(await leader.value)
        #expect(await follower.value)
        #expect(await session.count == 1)
    }

    @Test func unlimitedAndBoundedKeysAreDifferent() throws {
        let request = URLRequest(url: try #require(URL(string: "https://example.com")))
        #expect(
            RequestDedupKey(request: request, policy: .getOnly)
                != RequestDedupKey(request: request, policy: .getOnly, maximumResponseBytes: 100))
    }

    private func makeClient(_ session: LimitHeldSession) -> DefaultNetworkClient {
        DefaultNetworkClient(
            configuration: .advanced(
                baseURL: URL(string: "https://example.com")!, resilience: .init(coalescing: .getOnly)),
            session: session)
    }

    private func result(_ client: DefaultNetworkClient, limit: Int64) async -> Bool {
        do {
            let data = try await client.request(
                EncodedRequest<Data>(
                    method: .get, path: "/data", auth: .anonymous,
                    options: .init(maximumResponseBytes: limit), responseDecoder: .init { data, _ in data }))
            #expect(data.count == 10)
            return true
        } catch {
            if case .underlying(let underlying, _) = error {
                #expect(underlying.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue)
            } else {
                Issue.record("Expected a response collection limit failure, got \(error)")
            }
            return false
        }
    }
}

private actor LimitHeldSession: BoundedBufferedTestSession {
    nonisolated let allowsBoundedBufferedFallback = true
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    private var released = false
    private(set) var count = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        let ready = arrivals.filter { count >= $0.0 }
        arrivals.removeAll { count >= $0.0 }
        for item in ready { item.1.resume() }
        if !released { await withCheckedContinuation { pending.append($0) } }
        return (
            Data(repeating: 42, count: 10),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        )
    }

    func waitForEntries(_ target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { arrivals.append((target, $0)) }
    }

    func release() {
        released = true
        let saved = pending
        pending.removeAll()
        for item in saved { item.resume() }
    }
}
