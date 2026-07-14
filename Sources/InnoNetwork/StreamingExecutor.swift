import Foundation

/// Executes a ``StreamingAPIDefinition`` request as a long-lived line-delimited
/// stream. Owns per-attempt request preparation, line iteration, optional
/// Last-Event-ID resume, response interceptor application, and lifecycle event
/// publication so ``DefaultNetworkClient/stream(_:)`` stays a thin
/// `AsyncThrowingStream` factory.
///
/// The body of ``run(request:requestID:configuration:executionRuntime:inFlight:continuation:)``
/// preserves the same observable sequence the inline `stream(_:)` body emitted
/// before extraction:
///
/// 1. `requestStart` event
/// 2. session-level then per-endpoint request interceptors, then
///    `RefreshTokenPolicy.applyCurrentToken`
/// 3. `requestAdapted` event
/// 4. transport `bytes(for:context:)` call
/// 5. `responseReceived` event
/// 6. session-level response interceptors (the `Response.data` is intentionally
///    empty because stream contents are decoded line-by-line)
/// 7. acceptable status code validation with optional retry-policy handling
///    before any stream body bytes are consumed
/// 8. line iteration with `decode(line:)` and event id tracking
/// 9. resume decision when the iterator throws mid-stream
/// 10. `requestFinished` on clean completion or `requestFailed` on terminal error
package struct StreamingExecutor: Sendable {
    package let session: URLSessionProtocol
    package let eventHub: NetworkEventHub

    package init(session: URLSessionProtocol, eventHub: NetworkEventHub) {
        self.session = session
        self.eventHub = eventHub
    }

    package func run<T: StreamingAPIDefinition>(
        request: T,
        requestID: UUID,
        configuration: NetworkConfiguration,
        executionRuntime: RequestExecutionRuntime,
        inFlight: InFlightRegistry,
        continuation: AsyncThrowingStream<T.Output, Error>.Continuation
    ) async {
        do {
            try Self.validateAuthScope(request, configuration: configuration)
        } catch {
            let mapped = Self.mapTransportError(error, startedAt: nil)
            let nsError = mapped as NSError
            await eventHub.publish(
                .requestFailed(
                    requestID: requestID,
                    errorCode: nsError.code,
                    message: mapped.localizedDescription
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )
            await eventHub.finish(requestID: requestID)
            inFlight.deregister(id: requestID)
            continuation.finish(throwing: mapped)
            return
        }

        let resumePolicy = request.resumePolicy
        let resumeBudget = resumePolicy.maxAttempts
        let resumeDelay = resumePolicy.retryDelay
        var resumeState = StreamingResumeState()
        var resumeAttempts = 0
        var handshakeRetryState = StreamingHandshakeRetryState(
            snapshot: await configuration.networkMonitor?.currentSnapshot()
        )

        while true {
            do {
                let attemptRetryIndex = resumeAttempts + handshakeRetryState.retryIndex
                let attemptResult = try await runAttempt(
                    request: request,
                    requestID: requestID,
                    configuration: configuration,
                    executionRuntime: executionRuntime,
                    resumeState: &resumeState,
                    retryIndex: attemptRetryIndex,
                    continuation: continuation
                )

                switch attemptResult {
                case .transportFailure(let streamError, let attemptStartedAt):
                    // Mid-stream transport disconnect. Resume only when:
                    // - resume policy is active
                    // - attempt budget remains
                    // - this attempt observed a safe cursor (empty cursor
                    //   explicitly resets Last-Event-ID)
                    let canResume = resumeState.canResume(
                        maxAttempts: resumeBudget,
                        completedResumeAttempts: resumeAttempts
                    )
                    if canResume {
                        resumeAttempts += 1
                        try await Self.waitBeforeResume(
                            delay: resumeDelay,
                            executionRuntime: executionRuntime
                        )
                        try Task.checkCancellation()
                        continue
                    }
                    throw StreamingAttemptFailure(error: streamError, startedAt: attemptStartedAt)

                case .completed(let networkResponse, let streamedByteCount):
                    // Stream completed cleanly.
                    await eventHub.publish(
                        .requestFinished(
                            requestID: requestID,
                            statusCode: networkResponse.statusCode,
                            byteCount: streamedByteCount
                        ),
                        requestID: requestID,
                        observers: configuration.eventObservers
                    )
                    await eventHub.finish(requestID: requestID)
                    inFlight.deregister(id: requestID)
                    continuation.finish()
                    return
                }
            } catch {
                let failure = error as? StreamingAttemptFailure
                do {
                    if let failure,
                        try await retryHandshakeIfNeeded(
                            failure,
                            state: &handshakeRetryState,
                            configuration: configuration,
                            executionRuntime: executionRuntime,
                            requestID: requestID
                        )
                    {
                        continue
                    }
                } catch {
                    let mapped = Self.mapTransportError(
                        error,
                        startedAt: failure?.startedAt
                    )
                    let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                    let nsError = surfaced as NSError
                    await eventHub.publish(
                        .requestFailed(
                            requestID: requestID,
                            errorCode: nsError.code,
                            message: surfaced.localizedDescription
                        ),
                        requestID: requestID,
                        observers: configuration.eventObservers
                    )
                    await eventHub.finish(requestID: requestID)
                    inFlight.deregister(id: requestID)
                    continuation.finish(throwing: surfaced)
                    return
                }

                let mapped = Self.mapTransportError(
                    failure?.error ?? error,
                    startedAt: failure?.startedAt
                )
                let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                let nsError = surfaced as NSError
                await eventHub.publish(
                    .requestFailed(
                        requestID: requestID,
                        errorCode: nsError.code,
                        message: surfaced.localizedDescription
                    ),
                    requestID: requestID,
                    observers: configuration.eventObservers
                )
                await eventHub.finish(requestID: requestID)
                inFlight.deregister(id: requestID)
                continuation.finish(throwing: surfaced)
                return
            }
        }
    }

    // MARK: - Helpers

    private static func validateAuthScope<T: StreamingAPIDefinition>(
        _ request: T,
        configuration: NetworkConfiguration
    ) throws {
        _ = request
        guard T.Auth.self == AuthRequiredScope.self, configuration.refreshTokenPolicy == nil else {
            return
        }
        throw NetworkError.configuration(
            reason: .invalidRequest("Auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."))
    }

    private func runAttempt<T: StreamingAPIDefinition>(
        request: T,
        requestID: UUID,
        configuration: NetworkConfiguration,
        executionRuntime: RequestExecutionRuntime,
        resumeState: inout StreamingResumeState,
        retryIndex: Int,
        continuation: AsyncThrowingStream<T.Output, Error>.Continuation
    ) async throws -> StreamingAttemptResult {
        var attemptStartedAt: Date?
        var retryRequest: URLRequest?
        do {
            try Task.checkCancellation()
            resumeState.beginAttempt()
            var urlRequest = try Self.makeURLRequest(
                for: request,
                configuration: configuration,
                lastSeenEventID: resumeState.lastSeenEventID
            )
            retryRequest = urlRequest

            await eventHub.publish(
                .requestStart(
                    requestID: requestID,
                    method: urlRequest.httpMethod ?? "UNKNOWN",
                    url: urlRequest.url?.absoluteString ?? "",
                    retryIndex: retryIndex
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            urlRequest = try await applyRequestInterceptors(
                urlRequest,
                sessionInterceptors: configuration.requestInterceptors,
                endpointInterceptors: request.requestInterceptors,
                sessionSigners: configuration.requestSigners,
                endpointSigners: request.requestSigners,
                refreshCoordinator: executionRuntime.refreshCoordinator
            )
            retryRequest = urlRequest

            await eventHub.publish(
                .requestAdapted(
                    requestID: requestID,
                    method: urlRequest.httpMethod ?? "UNKNOWN",
                    url: urlRequest.url?.absoluteString ?? "",
                    retryIndex: retryIndex
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            let baseContext = NetworkRequestContext(
                requestID: requestID,
                retryIndex: retryIndex,
                metricsReporter: configuration.metricsReporter,
                trustPolicy: configuration.trustPolicy,
                eventObservers: configuration.eventObservers,
                redirectPolicy: configuration.redirectPolicy
            )
            let hasRequestSigners =
                !configuration.requestSigners.isEmpty || !request.requestSigners.isEmpty
            let context =
                hasRequestSigners ? baseContext.restrictingSignedRequestSharing() : baseContext
            attemptStartedAt = Date()
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: urlRequest, context: context)
            } catch {
                throw StreamingAttemptFailure(
                    error: error,
                    startedAt: attemptStartedAt,
                    phase: .handshake,
                    request: retryRequest
                )
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.nonHTTPResponse.rawValue,
                        message:
                            "Received a non-HTTP response on streaming request to \(NetworkError.diagnosticURLString(for: urlRequest.url)); response was \(type(of: response))."
                    ),
                    nil
                )
            }
            await eventHub.publish(
                .responseReceived(
                    requestID: requestID,
                    statusCode: httpResponse.statusCode,
                    byteCount: 0
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            var networkResponse = Response(
                statusCode: httpResponse.statusCode,
                data: Data(),
                request: urlRequest,
                response: httpResponse,
                kind: .headersOnly
            )
            for interceptor in configuration.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: urlRequest)
            }

            let acceptable = request.acceptableStatusCodes ?? configuration.acceptableStatusCodes
            guard acceptable.contains(networkResponse.statusCode) else {
                // Handshake failure: surface the status before consuming body
                // bytes so the outer loop can consult RetryPolicy without
                // mixing this budget with Last-Event-ID resume.
                throw StreamingAttemptFailure(
                    error: NetworkError.statusCode(networkResponse),
                    startedAt: attemptStartedAt,
                    phase: .handshake,
                    request: urlRequest
                )
            }

            let streamingLineByteLimit = max(1, configuration.streamingLineByteLimit)
            return try await consumeAttemptBytes(
                bytes,
                request: request,
                networkResponse: networkResponse,
                httpResponse: httpResponse,
                maxLineBytes: streamingLineByteLimit,
                resumeState: &resumeState,
                attemptStartedAt: attemptStartedAt,
                continuation: continuation
            )
        } catch let failure as StreamingAttemptFailure {
            throw failure
        } catch {
            throw StreamingAttemptFailure(error: error, startedAt: attemptStartedAt)
        }
    }

    private func consumeAttemptBytes<T: StreamingAPIDefinition>(
        _ bytes: URLSession.AsyncBytes,
        request: T,
        networkResponse: Response,
        httpResponse: HTTPURLResponse,
        maxLineBytes: Int,
        resumeState: inout StreamingResumeState,
        attemptStartedAt: Date?,
        continuation: AsyncThrowingStream<T.Output, Error>.Continuation
    ) async throws -> StreamingAttemptResult {
        var streamedByteCount = 0
        var iterator = bytes.makeAsyncIterator()
        while true {
            let frame: BoundedStreamLine?
            do {
                frame = try await Self.nextBoundedLine(
                    from: &iterator,
                    maxBytes: maxLineBytes
                )
            } catch is CancellationError {
                throw NetworkError.cancelled
            } catch let error as StreamingLineTooLargeError {
                throw Self.streamFrameTooLargeError(
                    byteCount: error.byteCount,
                    maxBytes: maxLineBytes,
                    networkResponse: networkResponse,
                    fallbackResponse: httpResponse
                )
            } catch {
                return .transportFailure(error, attemptStartedAt)
            }

            guard let frame else {
                return .completed(networkResponse, streamedByteCount)
            }
            let line = frame.line
            try Task.checkCancellation()
            streamedByteCount += frame.byteCount
            let decoded: T.Output?
            do {
                decoded = try request.decode(line: line)
            } catch {
                throw NetworkError.decoding(
                    stage: .streamFrame,
                    underlying: SendableUnderlyingError(error),
                    response: Response(
                        statusCode: networkResponse.statusCode,
                        data: Data(line.utf8),
                        request: networkResponse.request,
                        response: networkResponse.response ?? httpResponse
                    )
                )
            }
            if let output = decoded {
                if let eventID = request.eventID(from: output) {
                    if eventID.isEmpty {
                        resumeState.rejectEventID()
                    } else if Self.isValidLastEventIDCursor(eventID) {
                        resumeState.observe(eventID: eventID)
                    } else {
                        // Do not keep sending a stale cursor after a malformed
                        // custom id. An unsafe cursor makes this attempt
                        // non-resumable instead of replaying from an older id.
                        resumeState.rejectEventID()
                    }
                }
                continuation.yield(output)
            }
        }
    }

    package static func waitBeforeResume(
        delay: TimeInterval,
        executionRuntime: RequestExecutionRuntime
    ) async throws {
        guard delay > 0 else { return }
        try await executionRuntime.clock.sleep(for: .seconds(delay))
    }

    private func retryHandshakeIfNeeded(
        _ failure: StreamingAttemptFailure,
        state: inout StreamingHandshakeRetryState,
        configuration: NetworkConfiguration,
        executionRuntime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Bool {
        guard failure.phase == .handshake,
            let policy = configuration.retryPolicy
        else {
            return false
        }

        let networkError = Self.mapTransportError(failure.error, startedAt: failure.startedAt)
        let request = networkError.underlyingRequest ?? failure.request
        let decision = policy.shouldRetry(
            error: networkError,
            retryIndex: state.retryIndex,
            request: request,
            response: networkError.underlyingHTTPResponse
        )
        if case .noRetry = decision {
            return false
        }
        guard state.totalRetries < policy.maxTotalRetries else {
            return false
        }

        let computedDelay = policy.retryDelay(for: state.retryIndex)
        let delay = Self.retryDelay(
            for: decision,
            computedDelay: computedDelay,
            policy: policy
        )
        await eventHub.publish(
            .retryScheduled(
                requestID: requestID,
                retryIndex: state.retryIndex,
                delay: delay,
                reason: networkError.localizedDescription
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )

        var nextRetryIndex = state.retryIndex + 1
        var nextSnapshot = state.snapshot
        if policy.waitsForNetworkChanges, let monitor = configuration.networkMonitor {
            let newSnapshot = await monitor.waitForChange(
                from: nextSnapshot,
                timeout: policy.networkChangeTimeout
            )
            if policy.shouldResetAttempts(afterNetworkChangeFrom: nextSnapshot, to: newSnapshot) {
                nextRetryIndex = 0
            }
            if let newSnapshot {
                nextSnapshot = newSnapshot
            } else {
                nextSnapshot = await monitor.currentSnapshot() ?? nextSnapshot
            }
        }

        if delay > 0 {
            try await executionRuntime.clock.sleep(for: .seconds(delay))
        }

        state.retryIndex = nextRetryIndex
        state.totalRetries += 1
        state.snapshot = nextSnapshot
        try Task.checkCancellation()
        return true
    }

    private static func retryDelay(
        for decision: RetryDecision,
        computedDelay: TimeInterval,
        policy: RetryPolicy
    ) -> TimeInterval {
        switch decision {
        case .noRetry, .retry:
            return computedDelay
        case .retryAfter(let serverHint):
            let hintedDelay = max(serverHint, computedDelay)
            if let maxRetryAfterDelay = policy.maxRetryAfterDelay {
                return min(hintedDelay, max(maxRetryAfterDelay, computedDelay))
            }
            return hintedDelay
        }
    }

    private static func nextBoundedLine<Iterator: AsyncIteratorProtocol>(
        from iterator: inout Iterator,
        maxBytes: Int
    ) async throws -> BoundedStreamLine? where Iterator.Element == UInt8 {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maxBytes, 4 * 1024))

        while let byte = try await iterator.next() {
            if byte == 0x0A {
                if bytes.last == 0x0D {
                    bytes.removeLast()
                }
                return BoundedStreamLine(
                    line: String(decoding: bytes, as: UTF8.self),
                    byteCount: bytes.count
                )
            }

            bytes.append(byte)
            if bytes.count > maxBytes {
                throw StreamingLineTooLargeError(byteCount: bytes.count)
            }
        }

        guard !bytes.isEmpty else { return nil }
        if bytes.last == 0x0D {
            bytes.removeLast()
        }
        return BoundedStreamLine(
            line: String(decoding: bytes, as: UTF8.self),
            byteCount: bytes.count
        )
    }

    private static func streamFrameTooLargeError(
        byteCount: Int,
        maxBytes: Int,
        networkResponse: Response,
        fallbackResponse: HTTPURLResponse
    ) -> NetworkError {
        NetworkError.decoding(
            stage: .streamFrame,
            underlying: SendableUnderlyingError(
                domain: NetworkError.errorDomain,
                code: NetworkErrorCode.streamFrameTooLarge.rawValue,
                message:
                    "Streaming line exceeded \(maxBytes) bytes (saw \(byteCount))."
            ),
            response: Response(
                statusCode: networkResponse.statusCode,
                data: Data(),
                request: networkResponse.request,
                response: networkResponse.response ?? fallbackResponse,
                kind: .headersOnly
            )
        )
    }

    private static func makeURLRequest<T: StreamingAPIDefinition>(
        for request: T,
        configuration: NetworkConfiguration,
        lastSeenEventID: String?
    ) throws -> URLRequest {
        let url = try EndpointPathBuilder.makeURL(
            baseURL: configuration.baseURL,
            endpointPath: request.path,
            allowsInsecureHTTP: configuration.allowsInsecureHTTP
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.headers = request.headers
        urlRequest.cachePolicy = configuration.cachePolicy
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.networkServiceType = configuration.requestPriority.networkServiceType
        urlRequest.allowsCellularAccess = configuration.allowsCellularAccess
        urlRequest.allowsExpensiveNetworkAccess = configuration.allowsExpensiveNetworkAccess
        urlRequest.allowsConstrainedNetworkAccess = configuration.allowsConstrainedNetworkAccess
        if let lastSeenEventID, Self.isValidLastEventIDHeaderValue(lastSeenEventID) {
            urlRequest.setValue(lastSeenEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        return urlRequest
    }

    private static func isValidLastEventIDCursor(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (0x20...0x7E).contains(scalar.value)
        }
    }

    private static func isValidLastEventIDHeaderValue(_ value: String) -> Bool {
        guard value.isEmpty == false else { return false }
        return isValidLastEventIDCursor(value)
    }

    private func applyRequestInterceptors(
        _ urlRequest: URLRequest,
        sessionInterceptors: [RequestInterceptor],
        endpointInterceptors: [RequestInterceptor],
        sessionSigners: [RequestSigner],
        endpointSigners: [RequestSigner],
        refreshCoordinator: RefreshTokenCoordinator?
    ) async throws -> URLRequest {
        var current = urlRequest
        for interceptor in sessionInterceptors {
            current = try await interceptor.adapt(current)
        }
        for interceptor in endpointInterceptors {
            current = try await interceptor.adapt(current)
        }
        if let refreshCoordinator {
            current = try await refreshCoordinator.applyCurrentToken(to: current)
        }
        guard !sessionSigners.isEmpty || !endpointSigners.isEmpty else {
            return current
        }
        current = current.preparingForSignedTransport()
        let body = try BodySource.inline.signingBody(for: current)
        for signer in sessionSigners {
            let headers = try await signer.signatureHeaders(for: current, body: body)
            Self.apply(headers: headers, to: &current)
        }
        for signer in endpointSigners {
            let headers = try await signer.signatureHeaders(for: current, body: body)
            Self.apply(headers: headers, to: &current)
        }
        return current
    }

    private static func apply(headers: HTTPHeaders, to request: inout URLRequest) {
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
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

private struct BoundedStreamLine {
    let line: String
    let byteCount: Int
}

private struct StreamingHandshakeRetryState {
    var retryIndex = 0
    var totalRetries = 0
    var snapshot: NetworkSnapshot?
}

private enum StreamingAttemptResult {
    case completed(Response, Int)
    case transportFailure(Error, Date?)
}

private struct StreamingAttemptFailure: Error {
    enum Phase {
        case handshake
        case body
    }

    let error: Error
    let startedAt: Date?
    let phase: Phase
    let request: URLRequest?

    init(
        error: Error,
        startedAt: Date?,
        phase: Phase,
        request: URLRequest?
    ) {
        self.error = error
        self.startedAt = startedAt
        self.phase = phase
        self.request = request
    }

    init(error: Error, startedAt: Date?) {
        self.init(error: error, startedAt: startedAt, phase: .body, request: nil)
    }
}

private struct StreamingLineTooLargeError: Error {
    let byteCount: Int
}
