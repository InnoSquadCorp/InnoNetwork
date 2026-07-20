import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

extension ResiliencePolicyTests {
    @Test("Refresh token policy replays one 401 response")
    func refreshPolicyReplaysOnce() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 401),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "refreshed")),
        ])
        let refreshCount = ResilienceCounter()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await refreshCount.increment()
                return "new"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        let user = try await client.request(
            ResilienceGetRequest(sessionAuthentication: .optional)
        )

        #expect(user == ResilienceUser(id: 1, name: "refreshed"))
        #expect(await refreshCount.count == 1)
        #expect(await session.requestCount == 2)
        #expect(await session.capturedRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("Refresh replay preserves interceptor-adapted request state")
    func refreshReplayPreservesAdaptedInterceptorHeaders() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 401),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "refreshed")),
        ])
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: { "new" }
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                requestInterceptors: [
                    ResilienceHeaderSettingInterceptor(field: "X-Tenant-ID", value: "tenant-a"),
                    ResilienceHeaderSettingInterceptor(field: "X-Trace-ID", value: "trace-123"),
                ],
                refreshTokenPolicy: policy,
                responseBodyBufferingPolicy: .buffered(maxBytes: nil)
            ),
            session: session
        )

        let user = try await client.request(
            InterceptedResilienceGetRequest(
                interceptors: [
                    ResilienceHeaderSettingInterceptor(field: "X-Request-Signature", value: "signed")
                ],
                sessionAuthentication: .optional
            )
        )
        let capturedRequests = await session.capturedRequests

        #expect(user == ResilienceUser(id: 1, name: "refreshed"))
        #expect(capturedRequests.count == 2)
        #expect(capturedRequests[0].value(forHTTPHeaderField: "X-Tenant-ID") == "tenant-a")
        #expect(capturedRequests[0].value(forHTTPHeaderField: "X-Trace-ID") == "trace-123")
        #expect(capturedRequests[0].value(forHTTPHeaderField: "X-Request-Signature") == "signed")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "X-Tenant-ID") == "tenant-a")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "X-Trace-ID") == "trace-123")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "X-Request-Signature") == "signed")
        #expect(capturedRequests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("RefreshTokenPolicy appliesTo skips token attachment and replay")
    func refreshPolicyAppliesToSkipsTokenAttachmentAndReplay() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 401),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "unexpected")),
        ])
        let refreshCount = ResilienceCounter()
        let policy = RefreshTokenPolicy(
            appliesTo: { $0.url?.host == "auth.example.com" },
            currentToken: { "old" },
            refreshToken: {
                await refreshCount.increment()
                return "new"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(
                ResilienceGetRequest(sessionAuthentication: .optional)
            )
        }

        #expect(await session.requestCount == 1)
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(await refreshCount.count == 0)
    }

    @Test("Concurrent 401 responses share one refresh")
    func refreshPolicySingleFlight() async throws {
        let body = ResilienceUser(id: 1, name: "ok")
        let session = AuthorizationRoutingURLSession(
            oldTokenResponse: try resilienceQueuedResponse(statusCode: 401),
            newTokenResponse: try resilienceQueuedResponse(statusCode: 200, body: body)
        )
        let tokenStore = ResilienceTokenStore("old")
        let refreshGate = RefreshTestGate()
        let policy = RefreshTokenPolicy(
            currentToken: { await tokenStore.read() },
            refreshToken: {
                await refreshGate.enterAndWait()
                await tokenStore.replace(with: "new")
                return "new"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await client.request(
                        ResilienceGetRequest(sessionAuthentication: .optional)
                    )
                }
            }

            // Hold the single refresh until every caller has sent its old
            // token. This makes the coalescing cohort explicit even when the
            // parallel test scheduler delays individual child tasks.
            await session.waitForOldTokenRequests(count: 10)
            await refreshGate.release()

            for try await user in group {
                #expect(user == body)
            }
        }

        #expect(await refreshGate.totalEntryCount == 1)
    }

    @Test("Cancelled refresh waiter does not cancel shared refresh")
    func cancelledRefreshWaiterDoesNotCancelSharedRefresh() async throws {
        let body = ResilienceUser(id: 1, name: "ok")
        let session = AuthorizationRoutingURLSession(
            oldTokenResponse: try resilienceQueuedResponse(statusCode: 401),
            newTokenResponse: try resilienceQueuedResponse(statusCode: 200, body: body)
        )
        let tokenStore = ResilienceTokenStore("old")
        let refreshGate = RefreshTestGate()
        let policy = RefreshTokenPolicy(
            currentToken: { await tokenStore.read() },
            refreshToken: {
                await refreshGate.enterAndWait()
                await tokenStore.replace(with: "new")
                return "new"
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        let cancelled = Task {
            try await client.request(
                ResilienceGetRequest(sessionAuthentication: .optional)
            )
        }
        await refreshGate.waitUntilEntered()
        let remaining = Task {
            try await client.request(
                ResilienceGetRequest(sessionAuthentication: .optional)
            )
        }
        await session.waitForOldTokenRequests(count: 2)
        cancelled.cancel()

        await expectCancelled(cancelled)
        await refreshGate.release()
        let user = try await remaining.value

        #expect(user == body)
        #expect(await refreshGate.totalEntryCount == 1)
    }

    @Test("Refresh failure fans out to concurrent 401 waiters")
    func refreshFailureFansOut() async throws {
        var responses: [ResilienceQueuedHTTPResponse] = []
        for _ in 0..<5 {
            responses.append(try resilienceQueuedResponse(statusCode: 401))
        }
        let session = ResilienceSequenceURLSession(queue: responses)
        let refreshCount = ResilienceCounter()
        let policy = RefreshTokenPolicy(
            currentToken: { "old" },
            refreshToken: {
                await refreshCount.increment()
                try await Task.sleep(for: .milliseconds(50))
                throw NetworkError.configuration(reason: .invalidRequest("refresh failed"))
            }
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        try await client.request(
                            ResilienceGetRequest(sessionAuthentication: .optional)
                        )
                    }
                }
                for try await _ in group {}
            }
        }
        #expect(await refreshCount.count == 1)
        #expect(await session.requestCount == 5)
    }

    @Test("Replay stops after a second 401")
    func refreshPolicyStopsAfterReplay() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 401),
            resilienceQueuedResponse(statusCode: 401),
        ])
        let policy = RefreshTokenPolicy(currentToken: { "old" }, refreshToken: { "new" })
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                refreshTokenPolicy: policy
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(
                ResilienceGetRequest(sessionAuthentication: .optional)
            )
        }
        #expect(await session.requestCount == 2)
    }

    @Test("Default retry policy does not retry unsafe methods without idempotency key")
    func defaultRetryPolicyDoesNotRetryPostWithoutIdempotencyKey() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 503),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "unexpected")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0, jitterRatio: 0)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResiliencePostRequest())
        }
        #expect(await session.requestCount == 1)
    }

    @Test("Default retry policy retries unsafe methods with idempotency key")
    func defaultRetryPolicyRetriesPostWithIdempotencyKey() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 503),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "created")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 1, retryDelay: 0, jitterRatio: 0)
            ),
            session: session
        )

        let user = try await client.request(IdempotentResiliencePostRequest())

        #expect(user == ResilienceUser(id: 1, name: "created"))
        #expect(await session.requestCount == 2)
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "Idempotency-Key") == "create-user-1")
    }

    @Test("Method-agnostic retry policy keeps legacy unsafe-method retry behavior")
    func methodAgnosticRetryPolicyRetriesPostWithoutIdempotencyKey() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 503),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "legacy")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0,
                    idempotencyPolicy: .methodAgnostic
                )
            ),
            session: session
        )

        let user = try await client.request(ResiliencePostRequest())

        #expect(user == ResilienceUser(id: 1, name: "legacy"))
        #expect(await session.requestCount == 2)
    }

}
