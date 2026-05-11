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

    /// Hard ceiling on the per-line UTF-8 length the executor will accept
    /// before decoding a frame. Exceeding the budget surfaces as a
    /// ``NetworkError/decoding`` with stage ``DecodingStage/streamFrame`` so
    /// retry policies can act on the shape before one oversized line can pin
    /// unbounded memory.
    package static let maxStreamLineByteCount: Int = 1 << 20  // 1 MiB

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
                    // Handshake failure: do not retry. The status is a
                    // server-driven decision and re-sending the request
                    // is unlikely to change it within the stream's
                    // lifetime.
                    throw NetworkError.statusCode(networkResponse)
                }

                var streamedByteCount = 0
                var streamError: Error?
                var iterator = bytes.makeAsyncIterator()
                while true {
                    let frame: BoundedStreamLine?
                    do {
                        frame = try await Self.nextBoundedLine(
                            from: &iterator,
                            maxBytes: Self.maxStreamLineByteCount
                        )
                    } catch is CancellationError {
                        throw NetworkError.cancelled
                    } catch let error as StreamingLineTooLargeError {
                        throw Self.streamFrameTooLargeError(
                            byteCount: error.byteCount,
                            networkResponse: networkResponse,
                            fallbackResponse: httpResponse
                        )
                    } catch {
                        streamError = error
                        break
                    }

                    guard let frame else { break }
                    let line = frame.line
                    try Task.checkCancellation()
                    streamedByteCount += frame.byteCount
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
                        // Record the resume id *before* yielding so a
                        // mid-yield cancellation (or back-pressure stall
                        // on a buffered continuation) cannot drop the
                        // event id we'd need to send `Last-Event-ID` on
                        // a subsequent reconnect. `yield` is the
                        // suspension point an attacker on the wire (or a
                        // slow consumer) can stretch; the id assignment
                        // is local and synchronous.
                        resumeState.observe(eventID: request.eventID(from: output))
                        continuation.yield(output)
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
                        try await Self.waitBeforeResume(
                            delay: resumeDelay,
                            executionRuntime: executionRuntime
                        )
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

    package static func waitBeforeResume(
        delay: TimeInterval,
        executionRuntime: RequestExecutionRuntime
    ) async throws {
        guard delay > 0 else { return }
        try await executionRuntime.clock.sleep(for: .seconds(delay))
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
        networkResponse: Response,
        fallbackResponse: HTTPURLResponse
    ) -> NetworkError {
        NetworkError.decoding(
            stage: .streamFrame,
            underlying: SendableUnderlyingError(
                domain: NetworkError.errorDomain,
                code: NetworkErrorCode.streamFrameTooLarge.rawValue,
                message:
                    "Streaming line exceeded \(Self.maxStreamLineByteCount) bytes (saw \(byteCount))."
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

private struct BoundedStreamLine {
    let line: String
    let byteCount: Int
}

private struct StreamingLineTooLargeError: Error {
    let byteCount: Int
}
