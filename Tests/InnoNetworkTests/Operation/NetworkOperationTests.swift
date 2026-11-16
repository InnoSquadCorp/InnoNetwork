import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Network operation handle")
struct NetworkOperationTests {
    @Test("Operation returns a typed value and a bounded lifecycle")
    func returnsTypedValueAndLifecycle() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(PreviewResponse(id: "42"), for: endpoint)
        let client = stub

        let operation = client.start(endpoint)
        let value = try await operation.value()
        var events: [NetworkOperationEvent] = []
        for await event in operation.events {
            events.append(event)
        }

        #expect(value == PreviewResponse(id: "42"))
        #expect(events == [.started(id: operation.id), .succeeded(id: operation.id)])
        #expect(await operation.failureSummary() == nil)
    }

    @Test("Cancellation maps to the value-only failure contract")
    func mapsCancellation() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "never"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let operation = stub.start(endpoint)
        operation.cancel()

        await #expect(throws: NetworkError.self) {
            _ = try await operation.value()
        }
        do {
            _ = try await operation.value()
        } catch {
            #expect(error.category == .cancellation)
            #expect(error.summary.recovery == .none)
            #expect(await operation.failureSummary()?.recovery == NetworkRecoveryDisposition.none)
            #expect(operation.isCancelled)
        }
    }

    @Test("A summary removes payload details")
    func summaryRemovesPayloadDetails() {
        let failure = NetworkError.configuration(reason: .invalidRequest("secret detail")).summary

        #expect(failure.category == .configuration)
        #expect(failure.recovery == .doNotRetry)
        #expect(failure.statusCode == nil)
        #expect(failure.description == "The request configuration is invalid.")
        #expect(!String(reflecting: failure).contains("secret detail"))
    }

    @Test(
        "Recovery only recommends retry when replay is safe",
        arguments: [408, 429, 503]
    )
    func requiresReplaySafetyForRetry(statusCode: Int) async throws {
        let error = makeHTTPFailure(statusCode: statusCode)
        let client = FailingNetworkClient(error: error)

        let getFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .get))
        )
        let postFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .post))
        )
        let idempotentPostFailure = await failure(
            from: client.start(
                RecoveryEndpoint(method: .post),
                replaySafety: .stableIdempotencyKey
            )
        )
        let neverReplayGetFailure = await failure(
            from: client.start(
                RecoveryEndpoint(method: .get),
                replaySafety: .never
            )
        )

        #expect(getFailure.recovery == .retry)
        #expect(postFailure.recovery == .doNotRetry)
        #expect(idempotentPostFailure.recovery == .retry)
        #expect(neverReplayGetFailure.recovery == .doNotRetry)
    }

    @Test("Timeout recovery also requires replay safety")
    func requiresReplaySafetyForTimeoutRecovery() async throws {
        let error = NetworkError.timeout(reason: .requestTimeout)
        let client = FailingNetworkClient(error: error)

        let getFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .get))
        )
        let postFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .post))
        )

        #expect(getFailure.recovery == .retry)
        #expect(postFailure.recovery == .doNotRetry)
    }

    @Test("Connectivity recovery does not bypass replay safety")
    func requiresReplaySafetyForConnectivityRecovery() async throws {
        let underlying = SendableUnderlyingError(URLError(.networkConnectionLost))
        let error = NetworkError.reachability(
            .networkConnectionLost,
            underlying,
            nil
        )
        let client = FailingNetworkClient(error: error)

        let getFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .get))
        )
        let postFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .post))
        )

        #expect(getFailure.recovery == .waitForConnectivity)
        #expect(postFailure.recovery == .doNotRetry)
    }

    @Test("401 reauthenticates session endpoints while 403 stays terminal")
    func distinguishesAuthenticationFromAuthorization() async throws {
        let authenticated = RecoveryEndpoint(
            method: .get,
            sessionAuthentication: .required
        )
        let anonymous = RecoveryEndpoint(method: .get)

        let authenticated401 = await failure(
            from: FailingNetworkClient(error: makeHTTPFailure(statusCode: 401)).start(authenticated)
        )
        let anonymous401 = await failure(
            from: FailingNetworkClient(error: makeHTTPFailure(statusCode: 401)).start(anonymous)
        )
        let authenticated403 = await failure(
            from: FailingNetworkClient(error: makeHTTPFailure(statusCode: 403)).start(authenticated)
        )

        #expect(authenticated401.recovery == .reauthenticate)
        #expect(anonymous401.recovery == .doNotRetry)
        #expect(authenticated403.recovery == .doNotRetry)
    }

    @Test("A context-free summary never recommends replay")
    func contextFreeSummaryIsConservative() {
        let bodyLimit = NetworkError.policyRejected(
            .responseBodyLimitExceeded(limitBytes: 1_024, observedBytes: 4_096)
        ).summary
        #expect(bodyLimit.category == .policy)
        #expect(bodyLimit.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue)
        #expect(bodyLimit.recovery == .doNotRetry)

        let contextFreeServerFailure = makeHTTPFailure(statusCode: 503).summary
        #expect(contextFreeServerFailure.statusCode == 503)
        #expect(contextFreeServerFailure.recovery == .doNotRetry)
    }

    @Test("An unclassified transport failure follows the same transience rule as the retry hint")
    func transportFailureRecoveryMatchesRetryHint() async {
        let error = NetworkError.underlying(
            SendableUnderlyingError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, message: "bad"),
            nil
        )
        let client = FailingNetworkClient(error: error)

        let getFailure = await failure(from: client.start(RecoveryEndpoint(method: .get)))
        let postFailure = await failure(from: client.start(RecoveryEndpoint(method: .post)))

        #expect(error.isRetriableHint)
        #expect(getFailure.category == .transport)
        #expect(getFailure.recovery == .retry)
        #expect(postFailure.recovery == .doNotRetry)
    }

    @Test("Local rejections and failed refreshes have fixed recovery")
    func policyAndAuthenticationRecovery() async {
        let rejected = await failure(
            from: FailingNetworkClient(error: .policyRejected(.admissionQueueFull))
                .start(RecoveryEndpoint(method: .get))
        )
        #expect(rejected.category == .policy)
        #expect(rejected.recovery == .doNotRetry)

        let cause = SendableUnderlyingError(domain: "app.auth", code: 1, message: "revoked")
        let refresh = await failure(
            from: FailingNetworkClient(error: .authentication(.refreshFailed(cause)))
                .start(RecoveryEndpoint(method: .get))
        )
        #expect(refresh.category == .authentication)
        #expect(refresh.recovery == .reauthenticate)
        #expect(NetworkError.authentication(.refreshFailed(cause)).summary.recovery == .reauthenticate)
    }

    @Test("An offline failure waits for connectivity whatever the method or replay safety")
    func offlineRecoveryIgnoresReplaySafety() async {
        // The request never left the device, so waiting for a network cannot
        // repeat it.
        let offline = NetworkError.configuration(reason: .offline("No network."))
        let client = FailingNetworkClient(error: offline)

        let post = await failure(from: client.start(RecoveryEndpoint(method: .post)))
        let neverReplayed = await failure(
            from: client.start(RecoveryEndpoint(method: .get), replaySafety: .never)
        )

        #expect(post.category == .configuration)
        #expect(post.recovery == .waitForConnectivity)
        #expect(neverReplayed.recovery == .waitForConnectivity)
        #expect(offline.summary.recovery == .waitForConnectivity)
    }

    @Test("An expired or unrenewable credential asks to reauthenticate; other credential failures do not")
    func credentialRecovery() {
        #expect(RequestSecurityFailure.credentialExpired.networkError.summary.recovery == .reauthenticate)
        #expect(RequestSecurityFailure.refreshFailed.networkError.summary.recovery == .reauthenticate)
        #expect(RequestSecurityFailure.insufficientScope.networkError.summary.recovery == .doNotRetry)
    }

    @Test("The failed event carries the same contextual summary as the handle")
    func failedEventCarriesContextualSummary() async {
        let operation = FailingNetworkClient(error: makeHTTPFailure(statusCode: 503))
            .start(RecoveryEndpoint(method: .get))
        let summary = await failure(from: operation)

        var events: [NetworkOperationEvent] = []
        for await event in operation.events {
            events.append(event)
        }

        #expect(summary.recovery == .retry)
        #expect(events == [.started(id: operation.id), .failed(id: operation.id, summary: summary)])
    }

    @Test("An expired operation deadline fails before a delayed request completes")
    func expiresOperationDeadline() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "late"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let operation = stub.start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .zero)
        )

        let failure = await failure(from: operation)

        #expect(failure.category == .timeout)
        #expect(failure.code == NetworkErrorCode.timeout.rawValue)
        #expect(failure.deadlineStage == .requestPreparation)
        #expect(failure.recovery == .retry)
    }

    @Test("Unsafe operations keep deadline recovery terminal")
    func deadlineRecoveryRespectsReplaySafety() async throws {
        let endpoint = RecoveryEndpoint(method: .post)
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "late"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let operation = stub.start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .zero)
        )

        let failure = await failure(from: operation)

        #expect(failure.category == .timeout)
        #expect(failure.recovery == .doNotRetry)
    }

    @Test("A zero deadline never dispatches the base client")
    func zeroDeadlineDoesNotDispatch() async {
        let base = DeadlineHeldNetworkClient()
        let clock = TestClock()
        let operation = ClockedClient(base: base, deadlineClock: clock).start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .zero)
        )

        let result = await failure(from: operation)

        #expect(result.category == .timeout)
        #expect(await base.requestCount == 0)
        #expect(clock.waiterCount == 0)
    }

    @Test("An elapsed deadline cannot lose to a late successful response")
    func elapsedDeadlineWinsLateSuccess() async throws {
        let base = DeadlineHeldNetworkClient()
        let clock = TestClock()
        let operation = ClockedClient(base: base, deadlineClock: clock).start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(1))
        )

        await base.waitUntilStarted()
        #expect(await clock.waitForWaiters(count: 1))
        clock.advanceWithoutResuming(by: .seconds(2))
        await base.release()
        let result = await failure(from: operation)

        #expect(result.category == .timeout)
        #expect(result.deadlineStage == .requestPreparation)
        #expect(await base.requestCount == 1)
        clock.advance(by: .zero)
        #expect(clock.waiterCount == 0)
    }

    @Test("A successful operation cancels its pending deadline wait")
    func successCancelsDeadlineWait() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(PreviewResponse(id: "42"), for: endpoint)
        let clock = TestClock()
        let client = ClockedClient(base: stub, deadlineClock: clock)

        let value = try await client.start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .seconds(60))
        ).value()

        #expect(value == PreviewResponse(id: "42"))
        #expect(clock.waiterCount == 0)
    }

    @Test("Deadline reports retry-delay exhaustion")
    func reportsRetryDelayStage() async throws {
        let clock = TestClock()
        let session = DeadlineFailingURLSession()
        let base = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.test",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 5,
                    jitterRatio: 0
                )
            ),
            session: session,
            clock: clock
        )
        let client = ClockedClient(base: base, deadlineClock: clock)
        let operation = client.start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(2))
        )

        #expect(await clock.waitForWaiters(count: 2))
        clock.advance(by: .seconds(2))
        let failure = await failure(from: operation)

        #expect(failure.category == .timeout)
        #expect(failure.deadlineStage == .retryDelay)
        #expect(await session.requestCount == 1)
    }

    @Test("Caller cancellation wins over a pending operation deadline")
    func cancellationWinsPendingDeadline() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "late"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let clock = TestClock()
        let operation = ClockedClient(base: stub, deadlineClock: clock).start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .seconds(60))
        )

        operation.cancel()
        let failure = await failure(from: operation)

        #expect(failure.category == .cancellation)
        #expect(failure.deadlineStage == nil)
        #expect(clock.waiterCount == 0)
    }

    @Test(
        "Operation cancellation does not await a cancellation-noncooperative base",
        .timeLimit(.minutes(1))
    )
    func cancellationReturnsBeforeNoncooperativeBase() async throws {
        let base = CancellationHeldNetworkClient()
        let operation = base.start(PreviewEndpoint())
        await base.waitUntilStarted()

        let valueTask = Task {
            await failure(from: operation)
        }

        operation.cancel()
        await base.waitUntilCancelled()
        let result = await valueTask.value

        #expect(result.category == .cancellation)
        await base.release()
    }

    @Test(
        "Cancelling a value awaiter cancels its operation before the deadline",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func valueAwaiterCancellationPropagates(delayValueEntry: Bool) async throws {
        let base = CancellationHeldNetworkClient()
        let clock = TestClock()
        let operation = ClockedClient(base: base, deadlineClock: clock).start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(60))
        )
        let valueEntry = AsyncStream<Void>.makeStream()
        let handlerEntry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let valueTask = Task {
            defer { handlerEntry.continuation.finish() }
            if delayValueEntry {
                // Model an awaiter that reaches value() only after being cancelled.
                var iterator = valueEntry.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            return await failure(from: operation) { handlerEntry.continuation.yield(()) }
        }

        await withTaskCancellationHandler {
            await base.waitUntilStarted()
            #expect(await clock.waitForWaiters(count: 1))
            if !delayValueEntry {
                var installed = handlerEntry.stream.makeAsyncIterator()
                #expect(await installed.next() != nil)
            }
            valueTask.cancel()
            valueEntry.continuation.finish()
            handlerEntry.continuation.finish()
            // A yield does not prove value() installed its cancellation handler.
            // Observe cancellation completion before making the deadline eligible.
            let result = await valueTask.value

            #expect(result.category == .cancellation)
            #expect(result.deadlineStage == nil)
            #expect(clock.waiterCount == 0)
            clock.advance(by: .seconds(60))
            let afterDeadline = await failure(from: operation)
            #expect(afterDeadline == result)
        } onCancel: {
            valueEntry.continuation.finish()
            valueTask.cancel()
            operation.cancel()
        }
        await base.release()
        _ = await valueTask.value
        #expect(clock.waiterCount == 0)
    }

    @Test("Coalesced callers keep independent operation deadlines", .timeLimit(.minutes(1)))
    func coalescedCallersKeepIndependentDeadlines() async throws {
        let clock = TestClock()
        let session = DeadlineBlockingURLSession()
        let base = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.test",
                requestCoalescingPolicy: .getOnly
            ),
            session: session,
            clock: clock
        )
        let client = ClockedClient(base: base, deadlineClock: clock)
        let long = client.start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(10))
        )
        await session.waitUntilStarted()
        let short = client.start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(1))
        )

        await base.waitForCoalescedCallerCount(atLeast: 2)
        #expect(await clock.waitForWaiters(count: 2))
        clock.advance(by: .seconds(1))
        let shortFailure = await failure(from: short)

        #expect(shortFailure.deadlineStage == .transport)
        #expect(await session.requestCount == 1)

        try await session.succeed(with: PreviewResponse(id: "shared"))
        let longValue = try await long.value()

        #expect(longValue == PreviewResponse(id: "shared"))
        #expect(await session.requestCount == 1)
        #expect(clock.waiterCount == 0)
        await base.shutdown()
    }
}

/// Awaits a failing operation and returns its contextual summary.
private func failure<Value: Sendable>(
    from operation: NetworkOperation<Value>,
    onWait: @Sendable () -> Void = {}
) async -> NetworkErrorSummary {
    do {
        _ = try await operation.value(onWait: onWait)
        Issue.record("Expected the operation to fail")
        return NetworkError.configuration(reason: .invalidRequest("unexpected success")).summary
    } catch {
        return await operation.failureSummary() ?? error.summary
    }
}

/// Test adapter that pins the deadline clock for every operation it starts.
private struct ClockedClient<Base: NetworkClient>: Sendable {
    let base: Base
    let deadlineClock: any InnoNetworkClock

    func start<Request: APIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil
    ) -> NetworkOperation<Request.APIResponse> {
        base.start(
            request,
            replaySafety: replaySafety,
            deadline: deadline,
            deadlineClock: deadlineClock
        )
    }
}

private func makeHTTPFailure(statusCode: Int) -> NetworkError {
    let url = URL(string: "https://api.example.test/recovery")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return .statusCode(
        Response(
            statusCode: statusCode,
            data: Data(),
            response: response
        )
    )
}

private struct FailingNetworkClient: NetworkClient {
    let error: NetworkError

    func request<Request: APIDefinition>(
        _: Request,
        tag _: CancellationTag?
    ) async throws(NetworkError) -> Request.APIResponse {
        throw error
    }
}

private actor DeadlineFailingURLSession: URLSessionProtocol {
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        requestCount += 1
        throw URLError(.timedOut)
    }
}

private actor DeadlineBlockingURLSession: URLSessionProtocol {
    private var continuations: [CheckedContinuation<(Data, URLResponse), Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        requestCount += 1
        let pendingStarts = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingStarts { waiter.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with response: PreviewResponse) throws {
        let data = try JSONEncoder().encode(response)
        let urlResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.test/preview")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume(returning: (data, urlResponse))
        }
    }
}

private actor DeadlineHeldNetworkClient: NetworkClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    func request<Request: APIDefinition>(
        _: Request,
        tag _: CancellationTag?
    ) async throws(NetworkError) -> Request.APIResponse {
        requestCount += 1
        let pendingStarts = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingStarts { waiter.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        do {
            return try JSONDecoder().decode(
                Request.APIResponse.self,
                from: JSONEncoder().encode(PreviewResponse(id: "late"))
            )
        } catch {
            throw .configuration(reason: .invalidRequest("Unable to create the deadline test response."))
        }
    }

    func waitUntilStarted() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CancellationHeldNetworkClient: NetworkClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let cancellation = AsyncStream<Void>.makeStream()
    private var requestStarted = false

    func request<Request: APIDefinition>(
        _: Request,
        tag _: CancellationTag?
    ) async throws(NetworkError) -> Request.APIResponse {
        requestStarted = true
        started.continuation.yield()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            cancellation.continuation.yield()
        }
        guard !Task.isCancelled else { throw .cancelled }
        do {
            return try JSONDecoder().decode(
                Request.APIResponse.self,
                from: JSONEncoder().encode(PreviewResponse(id: "late"))
            )
        } catch {
            throw .configuration(reason: .invalidRequest("Unable to create the cancellation test response."))
        }
    }

    func waitUntilStarted() async {
        guard !requestStarted else { return }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilCancelled() async {
        var iterator = cancellation.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct RecoveryEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = PreviewResponse

    let method: HTTPMethod
    let path = "/recovery"
    let sessionAuthentication: SessionAuthentication
    let parameters: EmptyParameter? = nil

    init(
        method: HTTPMethod,
        sessionAuthentication: SessionAuthentication = .anonymous
    ) {
        self.method = method
        self.sessionAuthentication = sessionAuthentication
    }
}

private struct PreviewEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = PreviewResponse

    let method: HTTPMethod = .get
    let path = "/preview"
    let sessionAuthentication: SessionAuthentication = .anonymous
    let parameters: EmptyParameter? = nil
}

private struct PreviewResponse: Codable, Sendable, Equatable {
    let id: String
}
