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
/// 7. acceptable status code validation (handshake failure does not retry)
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
        let resumePolicy = request.resumePolicy
        let resumeBudget = resumePolicy.maxAttempts
        let resumeDelay = resumePolicy.retryDelay
        var resumeState = StreamingResumeState()
        var resumeAttempts = 0

        attempts: while true {
            var attemptStartedAt: Date?
            do {
                try Task.checkCancellation()
                resumeState.beginAttempt()
                var urlRequest = try Self.makeURLRequest(
                    for: request,
                    configuration: configuration,
                    lastSeenEventID: resumeState.lastSeenEventID
                )

                await eventHub.publish(
                    .requestStart(
                        requestID: requestID,
                        method: urlRequest.httpMethod ?? "UNKNOWN",
                        url: urlRequest.url?.absoluteString ?? "",
                        retryIndex: resumeAttempts
                    ),
                    requestID: requestID,
                    observers: configuration.eventObservers
                )

                urlRequest = try await applyRequestInterceptors(
                    urlRequest,
                    sessionInterceptors: configuration.requestInterceptors,
                    endpointInterceptors: request.requestInterceptors,
                    refreshCoordinator: executionRuntime.refreshCoordinator
                )

                await eventHub.publish(
                    .requestAdapted(
                        requestID: requestID,
                        method: urlRequest.httpMethod ?? "UNKNOWN",
                        url: urlRequest.url?.absoluteString ?? "",
                        retryIndex: resumeAttempts
                    ),
                    requestID: requestID,
                    observers: configuration.eventObservers
                )

                let context = NetworkRequestContext(
                    requestID: requestID,
                    retryIndex: resumeAttempts,
                    metricsReporter: configuration.metricsReporter,
                    trustPolicy: configuration.trustPolicy,
                    eventObservers: configuration.eventObservers,
                    redirectPolicy: configuration.redirectPolicy
                )
                attemptStartedAt = Date()
                let (bytes, response) = try await session.bytes(for: urlRequest, context: context)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.nonHTTPResponse(response)
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
                    response: httpResponse
                )
                for interceptor in configuration.responseInterceptors {
                    networkResponse = try await interceptor.adapt(networkResponse, request: urlRequest)
                }

                let acceptable = request.acceptableStatusCodes ?? configuration.acceptableStatusCodes
                guard acceptable.contains(networkResponse.statusCode) else {
                    // Handshake failure: do not retry. The status is a
                    // server-driven decision and re-sending the request
                    // is unlikely to change it within the stream's
                    // lifetime.
                    throw NetworkError.statusCode(networkResponse)
                }

                var streamedByteCount = 0
                var streamError: Error?
                var iterator = bytes.lines.makeAsyncIterator()
                while true {
                    let line: String?
                    do {
                        line = try await iterator.next()
                    } catch is CancellationError {
                        throw NetworkError.cancelled
                    } catch {
                        streamError = error
                        break
                    }

                    guard let line else { break }
                    try Task.checkCancellation()
                    streamedByteCount += line.utf8.count
                    let decoded: T.Output?
                    do {
                        decoded = try request.decode(line: line)
                    } catch {
                        // Per-frame decode failure: surface with the
                        // streamFrame stage so retry policies can tell
                        // "the framing was malformed" apart from a
                        // top-level body decode error. The Response
                        // carries the offending line's bytes (capped to
                        // a reasonable size by the line-iterator) so
                        // observability can sample it.
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
                        continuation.yield(output)
                        resumeState.observe(eventID: request.eventID(from: output))
                    }
                }

                if let streamError {
                    // Mid-stream transport disconnect. Resume only when:
                    // - resume policy is active
                    // - attempt budget remains
                    // - we have an event id to send (server cannot
                    //   resume from "nothing")
                    let canResume = resumeState.canResume(
                        maxAttempts: resumeBudget,
                        completedResumeAttempts: resumeAttempts
                    )
                    if canResume {
                        resumeAttempts += 1
                        if resumeDelay > 0 {
                            try? await Task.sleep(for: .seconds(resumeDelay))
                        }
                        try Task.checkCancellation()
                        continue attempts
                    }
                    throw Self.mapTransportError(
                        streamError,
                        startedAt: attemptStartedAt
                    )
                }

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
            } catch {
                let mapped = Self.mapTransportError(
                    error,
                    startedAt: attemptStartedAt
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
        if let lastSeenEventID {
            urlRequest.setValue(lastSeenEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        return urlRequest
    }

    private func applyRequestInterceptors(
        _ urlRequest: URLRequest,
        sessionInterceptors: [RequestInterceptor],
        endpointInterceptors: [RequestInterceptor],
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
        return current
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
