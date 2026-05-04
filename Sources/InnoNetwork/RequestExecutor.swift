import Foundation
import OSLog

private struct NotModifiedSubstitution {
    let mergedResponse: Response
    let preservedResponse: Response
    let cached: CachedResponse
}

struct BufferedAsyncBytes<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = [UInt8]

    private let bytes: Base
    private let chunkSize: Int
    private let maxBytes: Int64?

    init(_ bytes: Base, chunkSize: Int = 64 * 1024, maxBytes: Int64? = nil) {
        self.bytes = bytes
        self.chunkSize = Swift.max(1, chunkSize)
        self.maxBytes = maxBytes
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(
            iterator: bytes.makeAsyncIterator(),
            chunkSize: chunkSize,
            maxBytes: maxBytes
        )
    }

    struct Iterator: AsyncIteratorProtocol {
        private var iterator: Base.AsyncIterator
        private let chunkSize: Int
        private let maxBytes: Int64?
        private var observedBytes: Int64 = 0

        fileprivate init(iterator: Base.AsyncIterator, chunkSize: Int, maxBytes: Int64?) {
            self.iterator = iterator
            self.chunkSize = chunkSize
            self.maxBytes = maxBytes
        }

        mutating func next() async throws -> [UInt8]? {
            var chunk: [UInt8] = []
            chunk.reserveCapacity(chunkSize)
            while chunk.count < chunkSize {
                guard let byte = try await iterator.next() else { break }
                observedBytes += 1
                if let maxBytes, observedBytes > maxBytes {
                    throw NetworkError.responseTooLarge(limit: maxBytes, observed: observedBytes)
                }
                chunk.append(byte)
            }
            return chunk.isEmpty ? nil : chunk
        }
    }
}

package struct RequestExecutor {
    private let session: URLSessionProtocol
    private let eventHub: NetworkEventHub

    package init(session: URLSessionProtocol, eventHub: NetworkEventHub) {
        self.session = session
        self.eventHub = eventHub
    }

    package func execute<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration,
        requestBuilder: RequestBuilder,
        runtime: RequestExecutionRuntime,
        retryIndex: Int,
        requestID: UUID
    ) async throws -> D.APIResponse {
        try Task.checkCancellation()

        var retryRequest: URLRequest?
        var attemptStartedAt: Date?
        do {
            try validateAuthScope(executable, configuration: configuration)
            let built = try requestBuilder.build(executable, configuration: configuration)
            var request = built.request
            let cleanupFileURL: URL?
            if case .file(let fileURL, cleanupAfterUse: true) = built.bodySource {
                cleanupFileURL = fileURL
            } else {
                cleanupFileURL = nil
            }
            defer {
                if let cleanupFileURL {
                    try? FileManager.default.removeItem(at: cleanupFileURL)
                }
            }
            await notifyRequestStart(
                request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            // Onion model: session-level interceptors run first (outer), then
            // per-request interceptors (inner). Cross-cutting concerns
            // declared on NetworkConfiguration apply to every endpoint;
            // per-APIDefinition interceptors layer on top.
            for interceptor in configuration.requestInterceptors {
                request = try await interceptor.adapt(request)
            }
            for interceptor in executable.requestInterceptors {
                request = try await interceptor.adapt(request)
            }
            if let refreshCoordinator = runtime.refreshCoordinator {
                request = try await refreshCoordinator.applyCurrentToken(to: request)
            }
            retryRequest = request
            await notifyRequestAdapted(
                request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            executable.logger.log(request: request)

            let context = NetworkRequestContext(
                requestID: requestID,
                retryIndex: retryIndex,
                metricsReporter: configuration.metricsReporter,
                trustPolicy: configuration.trustPolicy,
                eventObservers: configuration.eventObservers,
                redirectPolicy: configuration.redirectPolicy
            )

            attemptStartedAt = Date()
            var networkResponse = try await executeWithPolicies(
                request: request,
                bodySource: built.bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                requestID: requestID
            )

            // Onion unwinds inner→outer: per-request interceptors first,
            // session-level interceptors last. A session-level response
            // interceptor sees the same response a session-only setup would
            // produce because per-endpoint adapters have already finished.
            for interceptor in executable.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: request)
            }
            for interceptor in configuration.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: request)
            }
            // After response interceptors settle, give cancellation a chance
            // to short-circuit before we spend cycles on body-limit checks,
            // decode, and didDecode chains.
            try Task.checkCancellation()
            try enforceResponseBodyLimit(networkResponse, configuration: configuration)

            // Per-endpoint override wins over the session-wide configuration
            // when present. Lets one definition treat e.g. 304 as success
            // without changing the default for the rest of the client.
            let acceptable = executable.acceptableStatusCodes ?? configuration.acceptableStatusCodes
            guard acceptable.contains(networkResponse.statusCode) else {
                throw NetworkError.statusCode(networkResponse)
            }

            executable.logger.log(response: networkResponse, isError: false)
            await eventHub.publish(
                .requestFinished(
                    requestID: requestID,
                    statusCode: networkResponse.statusCode,
                    byteCount: networkResponse.data.count
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            // willDecode runs after response interceptors have settled
            // so adapters that mutate the response (envelope rewriting,
            // header-driven sanitization) observe the same payload the
            // decoder will see. Interceptors fire in declaration order.
            var decodableData = networkResponse.data
            for interceptor in configuration.decodingInterceptors {
                decodableData = try await interceptor.willDecode(
                    data: decodableData,
                    response: networkResponse
                )
            }
            try enforceResponseBodyLimit(data: decodableData, configuration: configuration)

            // Synchronous decode can block for several ms on large payloads;
            // the surrounding async machinery would not check cancellation
            // again until didDecode runs, so insert a checkpoint here.
            try Task.checkCancellation()
            var decoded = try executable.decode(data: decodableData, response: networkResponse)
            for interceptor in configuration.decodingInterceptors {
                decoded = try await interceptor.didDecode(decoded, response: networkResponse)
            }
            return decoded
        } catch let error as NetworkError {
            let surfaced = configuration.captureFailurePayload ? error : error.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            await notifyFailure(surfaced, requestID: requestID, configuration: configuration)
            throw RequestExecutionFailure(error: surfaced, request: retryRequest ?? surfaced.underlyingRequest)
        } catch {
            let mapped = Self.mapTransportError(
                error,
                startedAt: attemptStartedAt
            )
            let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            await notifyFailure(surfaced, requestID: requestID, configuration: configuration)
            throw RequestExecutionFailure(error: surfaced, request: retryRequest ?? surfaced.underlyingRequest)
        }
    }

    private func validateAuthScope<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration
    ) throws {
        guard executable.requiresRefreshTokenPolicy, configuration.refreshTokenPolicy == nil else {
            return
        }
        throw NetworkError.invalidRequestConfiguration(
            "Auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."
        )
    }

    private func executeWithPolicies(
        request adaptedRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Response {
        var request = adaptedRequest
        var replayedAfterRefresh = false

        while true {
            let cacheKey = ResponseCacheKey(request: request)
            if let cachedResponse = try await cachedResponseIfAvailable(
                cacheKey: cacheKey,
                request: request,
                configuration: configuration,
                context: context,
                bodySource: bodySource,
                runtime: runtime,
                originalRequestID: requestID
            ) {
                return cachedResponse
            }

            try await prepareConditionalCacheHeaders(
                request: &request,
                cacheKey: cacheKey,
                configuration: configuration
            )

            let networkResponse = try await performTransport(
                request: request,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                requestID: requestID
            )

            if let substitution = await convertNotModifiedIfNeeded(
                networkResponse,
                cacheKey: cacheKey,
                request: request,
                configuration: configuration
            ) {
                if notModifiedRevisesVary(
                    cached: substitution.cached,
                    notModifiedHeaders: networkResponse.response?.allHeaderFields
                ) {
                    try enforceResponseBodyLimit(substitution.preservedResponse, configuration: configuration)
                    // The 304 advertises a different Vary dimension than the
                    // stored entry was keyed on. Rewriting with the new
                    // snapshot would silently move the entry to a different
                    // dimension; refresh `storedAt` instead so the freshness
                    // window reflects the successful revalidation while the
                    // stored representation remains addressable through its
                    // original Vary signature.
                    await refreshCachedFreshness(
                        cached: substitution.cached,
                        cacheKey: cacheKey,
                        configuration: configuration
                    )
                    return substitution.preservedResponse
                } else {
                    try enforceResponseBodyLimit(substitution.mergedResponse, configuration: configuration)
                    await storeCacheIfNeeded(
                        substitution.mergedResponse,
                        cacheKey: cacheKey,
                        request: request,
                        configuration: configuration
                    )
                    return substitution.mergedResponse
                }
            }

            if let refreshCoordinator = runtime.refreshCoordinator,
                await refreshCoordinator.shouldRefresh(statusCode: networkResponse.statusCode),
                !replayedAfterRefresh
            {
                // Replay from the fully adapted request so session and
                // endpoint interceptors keep their headers/signatures while
                // the auth policy replaces only the Authorization value.
                request = try await refreshCoordinator.refreshAndApply(to: adaptedRequest)
                replayedAfterRefresh = true
                continue
            }

            // Enforced before the response cache is written so an oversize
            // body cannot poison subsequent GETs that would replay it from
            // cache. The check is controlled by responseBodyBufferingPolicy;
            // nil keeps collection unbounded while still using the selected
            // streaming or buffered transport path.
            try enforceResponseBodyLimit(networkResponse, configuration: configuration)
            await storeCacheIfNeeded(
                networkResponse, cacheKey: cacheKey, request: request, configuration: configuration)
            return networkResponse
        }
    }

    private func enforceResponseBodyLimit(
        _ response: Response,
        configuration: NetworkConfiguration
    ) throws {
        try enforceResponseBodyLimit(data: response.data, configuration: configuration)
    }

    private func enforceResponseBodyLimit(
        data: Data,
        configuration: NetworkConfiguration
    ) throws {
        guard let limit = configuration.responseBodyBufferingPolicy.maxBytes else { return }
        let observed = Int64(data.count)
        if observed > limit {
            throw NetworkError.responseTooLarge(limit: limit, observed: observed)
        }
    }

    private func performTransport(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Response {
        try await executeCustomPolicies(
            request: request,
            bodySource: bodySource,
            configuration: configuration,
            context: context,
            runtime: runtime,
            requestID: requestID
        )
    }

    private func executeCustomPolicies(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Response {
        let eventHub = self.eventHub
        let baseNext = RequestExecutionNext { nextRequest in
            let result = try await performTransportResult(
                request: nextRequest,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime
            )
            await eventHub.publish(
                .responseReceived(
                    requestID: requestID,
                    statusCode: result.response.statusCode,
                    byteCount: result.data.count
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )
            return Response(
                statusCode: result.response.statusCode,
                data: result.data,
                request: nextRequest,
                response: result.response
            )
        }

        let policyContext = RequestExecutionContext(
            requestID: requestID,
            retryIndex: context.retryIndex,
            metricsReporter: context.metricsReporter,
            trustPolicy: context.trustPolicy,
            eventObservers: context.eventObservers
        )

        let chain = configuration.customExecutionPolicies.reversed().reduce(baseNext) { next, policy in
            RequestExecutionNext { nextRequest in
                try await policy.execute(
                    input: RequestExecutionInput(
                        request: nextRequest,
                        requestID: requestID,
                        retryIndex: context.retryIndex
                    ),
                    context: policyContext,
                    next: next
                )
            }
        }

        return try await chain.execute(request)
    }

    private func refreshLaneIfInProgress(
        coordinator: RefreshTokenCoordinator?
    ) async -> UUID? {
        guard let coordinator else { return nil }
        return await coordinator.isRefreshInProgress ? UUID() : nil
    }

    private func performTransportResult(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime
    ) async throws -> TransportResult {
        try await runtime.circuitBreakers.prepare(request: request, policy: configuration.circuitBreakerPolicy)

        // `prepare()` may have flipped a half-open probe slot to
        // `probeInFlight: true`. The await on `refreshLaneIfInProgress` and
        // the coalescer dispatch below are both cancellation points; if the
        // outer task is cancelled before transport runs, no `recordX` would
        // fire and the probe slot would stay held until GC. Wrap the rest
        // of the path so any pre-transport cancellation releases the slot.
        //
        // `transportAndRecordCircuit` records its own cancellation after
        // transport. To avoid double-recording on the rethrow path, the
        // inner method wraps cancellation in `CircuitBreakerHandledError`
        // so the outer catch knows it has already been accounted for.
        do {
            // When a refresh is in flight, segregate this caller into its own
            // coalescer lane so a stale 401 from a peer's pre-refresh transport
            // cannot be delivered as our result. When `Authorization` is part
            // of the dedup key (the default policy), this is a no-op for
            // correctness but pins the invariant; under
            // ``RequestCoalescingPolicy/excludedHeaderNames`` containing
            // `Authorization` it is the actual safeguard.
            let refreshLane: UUID? = await refreshLaneIfInProgress(coordinator: runtime.refreshCoordinator)

            if case .inline = bodySource,
                let key = RequestDedupKey(
                    request: request,
                    policy: configuration.requestCoalescingPolicy,
                    refreshLane: refreshLane
                )
            {
                return try await runtime.requestCoalescer.run(key: key) {
                    try await self.transportAndRecordCircuit(
                        request: request,
                        bodySource: bodySource,
                        configuration: configuration,
                        context: context,
                        runtime: runtime,
                        policy: configuration.circuitBreakerPolicy
                    )
                }
            }

            return try await transportAndRecordCircuit(
                request: request,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                policy: configuration.circuitBreakerPolicy
            )
        } catch let handled as CircuitBreakerHandledError {
            // Inner already recorded (cancellation OR failure); just unwrap
            // and rethrow so callers (`RetryCoordinator`, public API,
            // `NetworkError.isCancellation`) never observe the sentinel.
            throw handled.underlying
        } catch {
            // Anything reaching here did NOT pass through
            // `transportAndRecordCircuit`'s catch arm — typed throws from
            // `prepare()` (e.g. `circuitBreakerOpen`) and pre-transport
            // cancellation both land here. Only cancellation needs to
            // release the half-open probe slot; other typed errors are
            // owned by `prepare()` and should propagate unchanged. A rare
            // race where a coalescer-follower self-cancels while the
            // leader is still transporting can lead to two
            // `recordCancellation` calls for the same host key — the
            // operation is idempotent on `halfOpen(probeInFlight: true →
            // false)` and a no-op in `closed`/`open`, so this absorbs
            // safely without state corruption.
            if NetworkError.isCancellation(error) {
                await runtime.circuitBreakers.recordCancellation(
                    request: request,
                    policy: configuration.circuitBreakerPolicy
                )
            }
            throw error
        }
    }

    private func transportAndRecordCircuit(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        policy: CircuitBreakerPolicy?
    ) async throws -> TransportResult {
        do {
            let result = try await transport(
                request: request,
                bodySource: bodySource,
                configuration: configuration,
                context: context
            )
            await runtime.circuitBreakers.recordStatus(
                request: request,
                policy: policy,
                statusCode: result.response.statusCode
            )
            return result
        } catch {
            if NetworkError.isCancellation(error) {
                await runtime.circuitBreakers.recordCancellation(request: request, policy: policy)
            } else {
                await runtime.circuitBreakers.recordFailure(
                    request: request,
                    policy: policy,
                    error: error
                )
            }
            // Tag the error so `runWithCircuitBreaker`'s outer catch knows
            // the circuit breaker has already been notified for this throw.
            throw CircuitBreakerHandledError(underlying: error)
        }
    }

    /// Internal sentinel that marks a thrown error as already accounted for
    /// by `transportAndRecordCircuit`. The outer wrapper unwraps it before
    /// returning to callers so the public throw shape is unchanged.
    private struct CircuitBreakerHandledError: Error {
        let underlying: Error
    }

    private func transport(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext
    ) async throws -> TransportResult {
        let attemptStartedAt = Date()
        do {
            let (data, response): (Data, URLResponse)
            switch bodySource {
            case .inline:
                (data, response) = try await inlineData(for: request, configuration: configuration, context: context)
            case .file(let fileURL, _):
                (data, response) = try await session.upload(for: request, fromFile: fileURL, context: context)
            }

            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.nonHTTPResponse(response)
            }
            return TransportResult(data: data, response: httpResponse)
        } catch {
            throw NetworkError.mapTransportError(
                error,
                startedAt: attemptStartedAt,
                endedAt: Date(),
                resourceTimeoutInterval: nil
            )
        }
    }

    private func inlineData(
        for request: URLRequest,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext
    ) async throws -> (Data, URLResponse) {
        switch configuration.responseBodyBufferingPolicy {
        case .streaming(let maxBytes):
            do {
                let (bytes, response) = try await session.bytes(for: request, context: context)
                let data = try await collect(bytes: bytes, response: response, maxBytes: maxBytes)
                return (data, response)
            } catch let error as NetworkError {
                switch error {
                case .invalidRequestConfiguration:
                    // Falling back to a buffered transport silently bypasses
                    // the configured `maxBytes` ceiling, so honour the bound
                    // by surfacing the original error instead of collecting
                    // an unbounded body. Only the truly unbounded streaming
                    // mode (`maxBytes == nil`) is allowed to fall back.
                    guard maxBytes == nil else { throw error }
                    return try await session.data(for: request, context: context)
                default:
                    throw error
                }
            }
        case .buffered:
            return try await session.data(for: request, context: context)
        }
    }

    private func collect(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        maxBytes: Int64?
    ) async throws -> Data {
        let normalizedLimit = maxBytes.map { max(0, $0) }
        if let normalizedLimit,
            response.expectedContentLength > normalizedLimit
        {
            throw NetworkError.responseTooLarge(
                limit: normalizedLimit,
                observed: response.expectedContentLength
            )
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            let expectedBytes =
                normalizedLimit.map { min(response.expectedContentLength, $0) }
                ?? response.expectedContentLength
            data.reserveCapacity(Int(clamping: expectedBytes))
        }
        for try await chunk in BufferedAsyncBytes(bytes, maxBytes: normalizedLimit) {
            data.append(contentsOf: chunk)
        }
        return data
    }

    private func cachedResponseIfAvailable(
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        bodySource: BodySource,
        runtime: RequestExecutionRuntime,
        originalRequestID: UUID
    ) async throws -> Response? {
        guard let cacheKey,
            request.httpMethod?.uppercased() == "GET",
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheRead
        else {
            return nil
        }

        let cached = await cachedRespectingVary(cache, key: cacheKey, request: request)
        switch configuration.responseCachePolicy.prepare(cached: cached) {
        case .bypass, .revalidate:
            return nil
        case .returnCached(let cached):
            guard let httpResponse = cached.response(for: request) else { return nil }
            let response = Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            )
            try enforceResponseBodyLimit(response, configuration: configuration)
            return response
        case .returnStaleAndRevalidate(let cached):
            guard let httpResponse = cached.response(for: request) else { return nil }
            let staleResponse = Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            )
            try enforceResponseBodyLimit(staleResponse, configuration: configuration)

            let revalidationID = UUID()
            let startGate = TaskStartGate()
            let revalidationHandle = InFlightTaskHandle()
            runtime.inFlight.register(id: revalidationID) {
                revalidationHandle.cancel()
            }
            let eventHub = self.eventHub
            let revalidationTask = Task {
                await startGate.wait()
                defer {
                    runtime.inFlight.deregister(id: revalidationID)
                }
                var revalidationStartedAt: Date?
                let observers = context.eventObservers
                await eventHub.publish(
                    .cacheRevalidation(originalID: originalRequestID, state: .scheduled),
                    requestID: revalidationID,
                    observers: observers
                )

                do {
                    try Task.checkCancellation()

                    var revalidationRequest = request
                    if let etag = cached.etag {
                        revalidationRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
                    }

                    revalidationStartedAt = Date()
                    let result = try await revalidateInBackground(
                        request: revalidationRequest,
                        bodySource: bodySource,
                        configuration: configuration,
                        context: context,
                        runtime: runtime
                    )
                    try Task.checkCancellation()

                    let response = Response(
                        statusCode: result.response.statusCode,
                        data: result.data,
                        request: revalidationRequest,
                        response: result.response
                    )
                    let terminalState: CacheRevalidationState
                    if let substitution = await convertNotModifiedIfNeeded(
                        response,
                        cacheKey: cacheKey,
                        request: revalidationRequest,
                        configuration: configuration
                    ) {
                        try Task.checkCancellation()
                        if notModifiedRevisesVary(
                            cached: substitution.cached,
                            notModifiedHeaders: result.response.allHeaderFields
                        ) {
                            try enforceResponseBodyLimit(
                                substitution.preservedResponse,
                                configuration: configuration
                            )
                            await refreshCachedFreshness(
                                cached: substitution.cached,
                                cacheKey: cacheKey,
                                configuration: configuration
                            )
                        } else {
                            try enforceResponseBodyLimit(
                                substitution.mergedResponse,
                                configuration: configuration
                            )
                            await storeCacheIfNeeded(
                                substitution.mergedResponse,
                                cacheKey: cacheKey,
                                request: revalidationRequest,
                                configuration: configuration
                            )
                        }
                        terminalState = .notModified
                    } else {
                        try Task.checkCancellation()
                        try enforceResponseBodyLimit(response, configuration: configuration)
                        await storeCacheIfNeeded(
                            response, cacheKey: cacheKey, request: revalidationRequest, configuration: configuration)
                        terminalState = .completed(statusCode: result.response.statusCode)
                    }
                    await eventHub.publish(
                        .cacheRevalidation(originalID: originalRequestID, state: terminalState),
                        requestID: revalidationID,
                        observers: observers
                    )
                } catch {
                    if !NetworkError.isCancellation(error) {
                        let mapped = Self.mapTransportError(
                            error,
                            startedAt: revalidationStartedAt
                        )
                        let surfaced =
                            configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                        Logger.API.error(
                            "Background revalidation failed: \(surfaced.localizedDescription, privacy: .public)"
                        )
                        await eventHub.publish(
                            .cacheRevalidation(
                                originalID: originalRequestID,
                                state: .failed(
                                    errorCode: surfaced.errorCode,
                                    message: surfaced.localizedDescription
                                )
                            ),
                            requestID: revalidationID,
                            observers: observers
                        )
                    }
                }
                await eventHub.finish(requestID: revalidationID)
            }
            revalidationHandle.attach(revalidationTask)
            startGate.open()
            return staleResponse
        }
    }

    private func revalidateInBackground(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime
    ) async throws -> TransportResult {
        let revalidationContext = NetworkRequestContext(
            requestID: UUID(),
            retryIndex: context.retryIndex,
            metricsReporter: context.metricsReporter,
            trustPolicy: context.trustPolicy,
            eventObservers: context.eventObservers,
            redirectPolicy: context.redirectPolicy
        )
        return try await performTransportResult(
            request: request,
            bodySource: bodySource,
            configuration: configuration,
            context: revalidationContext,
            runtime: runtime
        )
    }

    private func prepareConditionalCacheHeaders(
        request: inout URLRequest,
        cacheKey: ResponseCacheKey?,
        configuration: NetworkConfiguration
    ) async throws {
        guard let cacheKey,
            request.httpMethod?.uppercased() == "GET",
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.isEnabled,
            configuration.responseCachePolicy.allowsConditionalRevalidation,
            let cached = await cachedRespectingVary(cache, key: cacheKey, request: request),
            let etag = cached.etag
        else {
            return
        }
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    private func convertNotModifiedIfNeeded(
        _ response: Response,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration
    ) async -> NotModifiedSubstitution? {
        guard response.statusCode == 304,
            configuration.responseCachePolicy.allowsConditionalRevalidation,
            let cacheKey,
            let cache = configuration.responseCache,
            let cached = await cachedRespectingVary(cache, key: cacheKey, request: request),
            let url = request.url,
            let preservedHTTPResponse = cached.response(for: request),
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: cached.statusCode,
                httpVersion: nil,
                headerFields: mergedCachedHeaders(cached.headers, notModifiedResponse: response.response)
            )
        else {
            return nil
        }
        return NotModifiedSubstitution(
            mergedResponse: Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            ),
            preservedResponse: Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: preservedHTTPResponse
            ),
            cached: cached
        )
    }

    /// Re-stores `cached` under `cacheKey` with a refreshed `storedAt`.
    ///
    /// Used on the 304 substitution path when the not-modified response
    /// advertises a different `Vary` dimension than the stored entry was
    /// keyed on. The stored representation, headers, and Vary snapshot are
    /// preserved verbatim; only the freshness timestamp moves forward so
    /// the entry honours the successful conditional revalidation without
    /// being silently rekeyed.
    private func refreshCachedFreshness(
        cached: CachedResponse,
        cacheKey: ResponseCacheKey?,
        configuration: NetworkConfiguration
    ) async {
        guard let cacheKey,
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheWrite
        else {
            return
        }
        await cache.set(
            cacheKey,
            CachedResponse(
                data: cached.data,
                statusCode: cached.statusCode,
                headers: cached.headers,
                storedAt: Date(),
                requiresRevalidation: cached.requiresRevalidation,
                varyHeaders: cached.varyHeaders
            )
        )
    }

    private func mergedCachedHeaders(
        _ cachedHeaders: [String: String],
        notModifiedResponse: HTTPURLResponse?
    ) -> [String: String] {
        var headers = cachedHeaders
        guard let notModifiedResponse else { return headers }

        for pair in notModifiedResponse.allHeaderFields {
            guard let key = pair.key as? String else { continue }
            let value = pair.value as? String ?? String(describing: pair.value)
            if let existingKey = headers.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                headers.removeValue(forKey: existingKey)
            }
            headers[key] = value
        }
        return headers
    }

    /// Stores the response in cache when the policy allows writes.
    ///
    /// Only GET responses are persisted. InnoNetwork stores the RFC-cacheable
    /// status codes that are safe for whole-response reuse and honours
    /// `Cache-Control: no-store` / `private` / `no-cache` without changing the
    /// explicit `ResponseCachePolicy` freshness window selected by the caller.
    private func storeCacheIfNeeded(
        _ response: Response,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration
    ) async {
        guard let cacheKey,
            request.httpMethod?.uppercased() == "GET",
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheWrite
        else {
            return
        }
        let headerSnapshot =
            response.response?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                guard let key = pair.key as? String, let value = pair.value as? String else { return }
                result[key] = value
            } ?? [:]
        guard Self.cacheableStatusCodes.contains(response.statusCode) else {
            return
        }
        let cacheControl = cacheControlDirectives(in: headerSnapshot)
        if cacheControl.contains("no-store") || cacheControl.contains("private") {
            await cache.invalidate(cacheKey)
            return
        }
        let varyHeaders: [String: String?]?
        switch evaluateVary(responseHeaders: headerSnapshot, request: request) {
        case .wildcardSkipsCache:
            return
        case .noVary:
            varyHeaders = nil
        case .vary(let snapshot):
            varyHeaders = snapshot
        }
        await cache.set(
            cacheKey,
            CachedResponse(
                data: response.data,
                statusCode: response.statusCode,
                headers: headerSnapshot,
                requiresRevalidation: cacheControl.contains("no-cache"),
                varyHeaders: varyHeaders
            )
        )
    }

    /// Status codes that are cacheable by default per RFC 9110 §15. `307`
    /// (Temporary Redirect) is intentionally omitted — RFC 9110 marks it as
    /// not cacheable by default, so caching it would silently change observed
    /// redirect behaviour.
    private static let cacheableStatusCodes: Set<Int> = [
        200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501,
    ]

    /// Parses Cache-Control directive *names* only. Quoted-string aware
    /// (RFC 9110 §5.6.4) so qualified directives like
    /// `private="X-Foo, X-Bar"` are not shredded into spurious tokens.
    private func cacheControlDirectives(in headers: [String: String]) -> Set<String> {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else { return [] }
        return Set(
            HTTPListParser.split(combined)
                .map(HTTPListParser.directiveName(of:))
                .filter { !$0.isEmpty }
        )
    }

    /// Returns the cached entry for `key` only when its stored vary snapshot
    /// matches `request`. Skips the result silently otherwise so the executor
    /// falls through to a fresh transport hit.
    private func cachedRespectingVary(
        _ cache: any ResponseCache,
        key: ResponseCacheKey,
        request: URLRequest
    ) async -> CachedResponse? {
        guard let cached = await cache.get(key) else { return nil }
        return cachedResponseMatchesVary(cached, request: request) ? cached : nil
    }

    private func notifyRequestStart(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await eventHub.publish(
            .requestStart(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    private func notifyRequestAdapted(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await eventHub.publish(
            .requestAdapted(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    private func notifyFailure(
        _ networkError: NetworkError,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        let nsError = networkError as NSError
        await eventHub.publish(
            .requestFailed(
                requestID: requestID,
                errorCode: nsError.code,
                message: networkError.localizedDescription
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    private static func mapTransportError(
        _ error: Error,
        startedAt: Date?
    ) -> NetworkError {
        guard let startedAt else { return NetworkError.mapTransportError(error) }
        return NetworkError.mapTransportError(
            error,
            startedAt: startedAt,
            endedAt: Date(),
            resourceTimeoutInterval: nil
        )
    }
}
