import Foundation


public protocol NetworkClient: Sendable {
    /// Executes a standard typed request modeled with ``APIDefinition``.
    ///
    /// Prefer this entry point for normal request/response APIs.
    ///
    /// - Parameter request: The typed request definition to execute.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    /// Executes a multipart request modeled with ``MultipartAPIDefinition``.
    ///
    /// Prefer this entry point for upload-style integrations.
    ///
    /// - Parameter request: The multipart request definition to execute.
    /// - Returns: The decoded `APIResponse` produced by the multipart request.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the multipart request.
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse
}

/// Low-level typed execution contract for framework authors and policy layers.
///
/// Application integrations should continue to depend on ``NetworkClient`` and use
/// ``NetworkClient/request(_:)`` or ``NetworkClient/upload(_:)``. Reach for this
/// protocol only when you need direct access to the execution pipeline.
public protocol LowLevelNetworkClient: Sendable {
    /// Executes a standard typed request through the low-level execution pipeline.
    ///
    /// `perform(_:)` is primarily intended for framework authors and policy layers
    /// that need to adapt richer request contracts into `InnoNetwork` without using
    /// SPI imports. Application integrations should normally prefer
    /// ``NetworkClient/request(_:)``.
    ///
    /// - Parameter request: The typed request definition to execute through the
    ///   low-level pipeline.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    func perform<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    /// Executes a custom request executable through the low-level execution pipeline.
    ///
    /// This overload exists for higher-level networking layers that want to control
    /// request serialization and decoding while still delegating execution, retry,
    /// and observability to `InnoNetwork`.
    ///
    /// - Parameter executable: The custom executable that owns request metadata,
    ///   payload creation, and response decoding.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    func perform<D: SingleRequestExecutable>(executable: D) async throws -> D.APIResponse
}


/// The default ``NetworkClient`` implementation.
///
/// Despite its `async throws` API surface, `DefaultNetworkClient` is an
/// **immutable value object**: every stored property is a `let` binding, and
/// all mutation lives behind the `eventHub` actor, the URL session, and the
/// retry coordinator structs. The type therefore conforms to `Sendable`
/// without crossing an actor isolation boundary on every call — concurrent
/// `request(_:)` invocations execute in parallel as soon as they reach
/// ``URLSessionProtocol/data(for:context:)``, the same as in the previous
/// `actor` form (which already released isolation on every `await`).
public final class DefaultNetworkClient: NetworkClient, LowLevelNetworkClient, Sendable {
    private let configuration: NetworkConfiguration
    private let session: URLSessionProtocol
    private let requestBuilder = RequestBuilder()
    private let eventHub: NetworkEventHub
    private let inFlight = InFlightRegistry()

    public init(
        configuration: NetworkConfiguration,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.configuration = configuration
        self.session = session
        self.eventHub = NetworkEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .networkRequest
        )
    }

    /// Begins a long-lived streaming request and returns an
    /// `AsyncThrowingStream` of decoded line payloads.
    ///
    /// Streaming requests bypass the configured ``RetryPolicy`` because a
    /// half-consumed stream cannot be replayed transparently. Outer-task
    /// cancellation propagates to the underlying transport via
    /// `AsyncThrowingStream.Continuation.onTermination`, and ``cancelAll()``
    /// reaches stream tasks the same way it reaches request tasks.
    ///
    /// Response interceptors on ``NetworkConfiguration`` receive only the
    /// response metadata for streaming requests. Their ``Response/data`` is
    /// empty because stream contents are decoded line-by-line after headers
    /// arrive; body-inspecting interceptors should stay on non-streaming
    /// ``request(_:)``/``upload(_:)`` paths. Per-endpoint response
    /// interceptors are not part of ``StreamingAPIDefinition`` and therefore
    /// are not run for streams.
    ///
    /// - Parameter request: The streaming endpoint to subscribe to.
    /// - Returns: An `AsyncThrowingStream<T.Output, Error>` whose values are
    ///   the non-nil results of ``StreamingAPIDefinition/decode(line:)``.
    public func stream<T: StreamingAPIDefinition>(_ request: T) -> AsyncThrowingStream<T.Output, Error> {
        AsyncThrowingStream { continuation in
            let requestID = UUID()
            let inFlight = self.inFlight
            let configuration = self.configuration
            let session = self.session
            let eventHub = self.eventHub
            let startGate = TaskStartGate()

            let work = Task<Void, Never> {
                await startGate.wait()

                let resumePolicy = request.resumePolicy
                let resumeBudget = resumePolicy.maxAttempts
                let resumeDelay = resumePolicy.retryDelay
                var lastSeenEventID: String? = nil
                var resumeAttempts = 0

                attempts: while true {
                    do {
                        try Task.checkCancellation()
                        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent(request.path))
                        urlRequest.httpMethod = request.method.rawValue
                        urlRequest.allHTTPHeaderFields = request.headers.dictionary
                        urlRequest.cachePolicy = configuration.cachePolicy
                        urlRequest.timeoutInterval = configuration.timeout
                        if let lastSeenEventID {
                            urlRequest.setValue(lastSeenEventID, forHTTPHeaderField: "Last-Event-ID")
                        }

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

                        for interceptor in configuration.requestInterceptors {
                            urlRequest = try await interceptor.adapt(urlRequest)
                        }
                        for interceptor in request.requestInterceptors {
                            urlRequest = try await interceptor.adapt(urlRequest)
                        }
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
                            eventObservers: configuration.eventObservers
                        )
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
                            if let output = try request.decode(line: line) {
                                continuation.yield(output)
                                if let id = request.eventID(from: output) {
                                    lastSeenEventID = id
                                }
                            }
                        }

                        if let streamError {
                            // Mid-stream transport disconnect. Resume only when:
                            // - resume policy is active
                            // - attempt budget remains
                            // - we have an event id to send (server cannot
                            //   resume from "nothing")
                            let canResume = resumeBudget > 0
                                && resumeAttempts < resumeBudget
                                && lastSeenEventID != nil
                            if canResume {
                                resumeAttempts += 1
                                if resumeDelay > 0 {
                                    try? await Task.sleep(for: .seconds(resumeDelay))
                                }
                                try Task.checkCancellation()
                                continue attempts
                            }
                            throw NetworkError.mapTransportError(streamError)
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
                        let mapped = NetworkError.mapTransportError(error)
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

            continuation.onTermination = { _ in
                work.cancel()
            }
            inFlight.register(id: requestID, cancelHandler: { work.cancel() })
            startGate.open()
        }
    }

    /// Cancels every request currently dispatched through this client.
    ///
    /// Each in-flight request is interrupted at its next cooperative
    /// cancellation checkpoint and surfaces ``NetworkError/cancelled`` to its
    /// caller. Requests that have already produced a result before cancellation
    /// reaches them complete normally.
    ///
    /// Typical use is during sign-out, screen disposal, or auth invalidation:
    /// the client can be drained without waiting for individual `Task`
    /// references to be tracked by the call site.
    public func cancelAll() async {
        inFlight.cancelAll()
    }

    public func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(request)
    }
    
    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(executable: MultipartSingleRequestExecutable(base: request))
    }

    /// Low-level typed execution entry point for standard ``APIDefinition`` requests.
    ///
    /// Use this when you need to make the execution pipeline itself the dependency
    /// boundary. Most app integrations should still prefer ``request(_:)``.
    ///
    /// - Parameter request: The typed request definition to execute through the
    ///   low-level pipeline.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    public func perform<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(executable: APISingleRequestExecutable(base: request))
    }

    /// Low-level typed execution entry point for custom ``SingleRequestExecutable`` values.
    ///
    /// This API is intended for upper networking layers that need full control over
    /// serialization and decoding but still want `InnoNetwork` to own request
    /// building, retry coordination, trust handling, and observability.
    ///
    /// - Parameter executable: The custom executable that owns request metadata,
    ///   payload creation, and response decoding.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    public func perform<D: SingleRequestExecutable>(executable: D) async throws -> D.APIResponse {
        let requestID = UUID()
        let startGate = TaskStartGate()
        // Wrap the work in an unstructured Task so cancelAll() can reach it
        // without the call site having to track individual Task handles.
        // Outer-task cancellation is forwarded via withTaskCancellationHandler.
        let work = Task<D.APIResponse, Error> { [eventHub, configuration, session, requestBuilder] in
            await startGate.wait()
            let retryCoordinator = RetryCoordinator(eventHub: eventHub)
            return try await retryCoordinator.execute(
                retryPolicy: configuration.retryPolicy,
                networkMonitor: configuration.networkMonitor,
                requestID: requestID,
                eventObservers: configuration.eventObservers
            ) { retryIndex, requestID in
                try await RequestExecutor(session: session, eventHub: eventHub).execute(
                    executable,
                    configuration: configuration,
                    requestBuilder: requestBuilder,
                    retryIndex: retryIndex,
                    requestID: requestID
                )
            }
        }
        inFlight.register(id: requestID, cancelHandler: { work.cancel() })
        startGate.open()

        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            inFlight.deregister(id: requestID)
            return result
        } catch {
            inFlight.deregister(id: requestID)
            throw error
        }
    }
}
