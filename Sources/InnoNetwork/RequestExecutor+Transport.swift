import Foundation

// MARK: - Transport stage
//
// Owns the actual URLSession dispatch, body collection, circuit-breaker
// recording, and the response-body-limit enforcement helper. Custom
// policies and the surrounding pipeline live in `RequestExecutor+Pipeline`.

extension RequestExecutor {
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
            throw NetworkError.underlying(
                SendableUnderlyingError(
                    domain: NetworkError.errorDomain,
                    code: NetworkErrorCode.responseBodyLimitExceeded.rawValue,
                    message: "Response body of \(observed) bytes exceeded the configured limit of \(limit) bytes."
                ),
                nil
            )
        }
    }

    func performTransport(
        request: URLRequest,
        identityRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID,
        allowsRequestCoalescing: Bool
    ) async throws -> Response {
        try await executeCustomPolicies(
            request: request,
            identityRequest: identityRequest,
            bodySource: bodySource,
            configuration: configuration,
            context: context,
            runtime: runtime,
            requestID: requestID,
            allowsRequestCoalescing: allowsRequestCoalescing
        )
    }

    func performTransportResult(
        request: URLRequest,
        identityRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        allowsRequestCoalescing: Bool
    ) async throws -> TransportResult {
        try await runtime.circuitBreakers.prepare(
            request: identityRequest,
            policy: configuration.circuitBreakerPolicy
        )

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

            if allowsRequestCoalescing,
                case .inline = bodySource,
                let key = RequestDedupKey(
                    request: identityRequest,
                    policy: configuration.requestCoalescingPolicy,
                    refreshLane: refreshLane
                )
            {
                return try await runtime.requestCoalescer.run(key: key) {
                    try await self.transportAndRecordCircuit(
                        request: request,
                        identityRequest: identityRequest,
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
                identityRequest: identityRequest,
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
                    request: identityRequest,
                    policy: configuration.circuitBreakerPolicy
                )
            }
            throw error
        }
    }

    func transportAndRecordCircuit(
        request: URLRequest,
        identityRequest: URLRequest,
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
                request: identityRequest,
                policy: policy,
                statusCode: result.response.statusCode
            )
            return result
        } catch {
            if NetworkError.isCancellation(error) {
                await runtime.circuitBreakers.recordCancellation(request: identityRequest, policy: policy)
            } else {
                await runtime.circuitBreakers.recordFailure(
                    request: identityRequest,
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
    fileprivate struct CircuitBreakerHandledError: Error {
        let underlying: Error
    }

    func transport(
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
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.nonHTTPResponse.rawValue,
                        message:
                            "Received a non-HTTP response from \(NetworkError.diagnosticURLString(for: request.url)); response was \(type(of: response))."
                    ),
                    nil
                )
            }
            return TransportResult(data: data, response: httpResponse)
        } catch let networkError as NetworkError {
            // Already classified by an inner layer (e.g. responseBodyLimitExceeded
            // from `collect(bytes:response:maxBytes:)`). Rethrow as-is so the
            // task-interval contextual remap below cannot mis-attribute a
            // post-headers body-size failure as a transport timeout — the
            // bytes already arrived before the limit fired.
            throw networkError
        } catch {
            throw NetworkError.mapTransportError(
                error,
                startedAt: attemptStartedAt,
                endedAt: Date(),
                resourceTimeoutInterval: nil
            )
        }
    }

    func inlineData(
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
                case .configuration(reason: .invalidRequest):
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

    func collect(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        maxBytes: Int64?
    ) async throws -> Data {
        let normalizedLimit = maxBytes.map { max(0, $0) }
        if let normalizedLimit,
            response.expectedContentLength > normalizedLimit
        {
            throw NetworkError.underlying(
                SendableUnderlyingError(
                    domain: NetworkError.errorDomain,
                    code: NetworkErrorCode.responseBodyLimitExceeded.rawValue,
                    message:
                        "Response body of \(response.expectedContentLength) bytes exceeded the configured limit of \(normalizedLimit) bytes."
                ),
                nil
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
