import Foundation
import OSLog


package struct RequestExecutor {
    private let session: URLSessionProtocol
    let eventHub: NetworkEventHub

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
            configuration.idempotencyKeyPolicy.apply(to: &request, requestID: requestID)
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
                await refreshCoordinator.shouldRefresh(statusCode: networkResponse.statusCode, request: request),
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

    func enforceResponseBodyLimit(
        _ response: Response,
        configuration: NetworkConfiguration
    ) throws {
        try enforceResponseBodyLimit(data: response.data, configuration: configuration)
    }

    func enforceResponseBodyLimit(
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

    func performTransportResult(
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

    static func mapTransportError(
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
