import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

extension ResiliencePolicyTests {
    @Test("GET coalescing shares one transport")
    func getCoalescingSharesTransport() async throws {
        let session = try ResilienceSequenceURLSession(
            queue: [resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "shared"))],
            delay: .milliseconds(50)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await client.request(ResilienceGetRequest())
                }
            }
            for try await user in group {
                #expect(user == ResilienceUser(id: 1, name: "shared"))
            }
        }

        #expect(await session.requestCount == 1)
    }

    @Test("POST is not coalesced by getOnly policy")
    func postDoesNotCoalesceByDefault() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "one")),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "two")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        _ = try await client.request(ResiliencePostRequest())
        _ = try await client.request(ResiliencePostRequest())

        #expect(await session.requestCount == 2)
    }

    @Test("Coalescing method allowlists preserve case-sensitive tokens")
    func coalescingMethodAllowlistIsCaseSensitive() throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/options")!)
        request.httpMethod = "options"

        let uppercasePolicy = RequestCoalescingPolicy(methods: ["OPTIONS"])
        #expect(uppercasePolicy.methods == ["OPTIONS"])
        #expect(RequestDedupKey(request: request, policy: uppercasePolicy) == nil)

        let lowercasePolicy = RequestCoalescingPolicy(methods: ["options"])
        let key = try #require(RequestDedupKey(request: request, policy: lowercasePolicy))
        #expect(key.method == "options")
    }

    @Test("Coalescing keeps different Authorization headers separate")
    func coalescingSeparatesAuthorizationHeaders() async throws {
        let session = try ResilienceSequenceURLSession(
            queue: [
                resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "one")),
                resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "two")),
            ],
            delay: .milliseconds(50)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        async let first = client.request(AuthorizedResilienceGetRequest(token: "one"))
        async let second = client.request(AuthorizedResilienceGetRequest(token: "two"))
        let users = try await [first, second]

        #expect(users.contains(ResilienceUser(id: 1, name: "one")))
        #expect(users.contains(ResilienceUser(id: 2, name: "two")))
        #expect(await session.requestCount == 2)
    }

    @Test("Partial coalescing waiter cancellation keeps remaining waiter alive")
    func partialCoalescingCancellationKeepsRemainingWaiterAlive() async throws {
        let session = try ResilienceSequenceURLSession(
            queue: [resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "shared"))],
            delay: .milliseconds(100)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        let cancelled = Task {
            try await client.request(ResilienceGetRequest())
        }
        let remaining = Task {
            try await client.request(ResilienceGetRequest())
        }

        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()

        await expectCancelled(cancelled)
        let user = try await remaining.value

        #expect(user == ResilienceUser(id: 1, name: "shared"))
        #expect(await session.requestCount == 1)
    }

    @Test("All coalescing waiter cancellation cancels shared transport")
    func allCoalescingCancellationCancelsSharedTransport() async throws {
        let session = try CancellationFirstURLSession(
            queue: [
                resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "first"))
            ]
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly
            ),
            session: session
        )

        let first = Task {
            try await client.request(ResilienceGetRequest())
        }
        let second = Task {
            try await client.request(ResilienceGetRequest())
        }

        try await waitUntil {
            await session.requestCount == 1
        }
        first.cancel()
        second.cancel()

        await expectCancelled(first)
        await expectCancelled(second)
        try await waitUntil {
            await session.cancelledRequestCount == 1
        }

        let recovered = try await client.request(ResilienceGetRequest())

        #expect(recovered == ResilienceUser(id: 1, name: "first"))
        #expect(await session.requestCount == 2)
    }

    @Test("Coalescer cancellation bookkeeping is TTL pruned and capped")
    func coalescerCancellationBookkeepingIsBounded() async throws {
        var request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        request.httpMethod = "GET"
        let key = try #require(RequestDedupKey(request: request, policy: .getOnly))
        let now = Date(timeIntervalSince1970: 62)
        let coalescer = RequestCoalescer(
            cancelledWaiterTTL: 30,
            cancelledWaiterLimit: 2,
            now: { now }
        )

        await coalescer.recordCancelledWaiterForDiagnostics(
            key: key,
            waiterID: UUID(),
            recordedAt: Date(timeIntervalSince1970: 0)
        )
        await coalescer.recordCancelledWaiterForDiagnostics(
            key: key,
            waiterID: UUID(),
            recordedAt: Date(timeIntervalSince1970: 60)
        )
        await coalescer.recordCancelledWaiterForDiagnostics(
            key: key,
            waiterID: UUID(),
            recordedAt: Date(timeIntervalSince1970: 61)
        )
        await coalescer.recordCancelledWaiterForDiagnostics(
            key: key,
            waiterID: UUID(),
            recordedAt: Date(timeIntervalSince1970: 62)
        )

        #expect(await coalescer.cancellationBookkeepingCount == 2)
    }

    @Test("Request runtime injects its virtual clock into coalescer pruning")
    func runtimeClockDrivesCoalescerPruning() async throws {
        let clock = TestClock(epoch: Date(timeIntervalSince1970: 1_000))
        let runtime = RequestExecutionRuntime(
            configuration: NetworkConfiguration(baseURL: URL(string: "https://api.example.com")!),
            inFlight: InFlightRegistry(),
            clock: clock
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        request.httpMethod = "GET"
        let key = try #require(RequestDedupKey(request: request, policy: .getOnly))

        await runtime.requestCoalescer.recordCancelledWaiterForDiagnostics(
            key: key,
            waiterID: UUID(),
            recordedAt: clock.now()
        )
        #expect(await runtime.requestCoalescer.cancellationBookkeepingCount == 1)

        clock.advance(by: .seconds(31))
        #expect(await runtime.requestCoalescer.cancellationBookkeepingCount == 0)
    }

}
