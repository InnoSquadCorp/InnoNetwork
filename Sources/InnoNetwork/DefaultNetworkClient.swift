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

            let work = Task<Void, Never> {
                do {
                    var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent(request.path))
                    urlRequest.httpMethod = request.method.rawValue
                    urlRequest.allHTTPHeaderFields = request.headers.dictionary
                    urlRequest.cachePolicy = configuration.cachePolicy
                    urlRequest.timeoutInterval = configuration.timeout

                    for interceptor in configuration.requestInterceptors {
                        urlRequest = try await interceptor.adapt(urlRequest)
                    }
                    for interceptor in request.requestInterceptors {
                        urlRequest = try await interceptor.adapt(urlRequest)
                    }

                    let context = NetworkRequestContext(
                        requestID: requestID,
                        retryIndex: 0,
                        metricsReporter: configuration.metricsReporter,
                        trustPolicy: configuration.trustPolicy,
                        eventObservers: configuration.eventObservers
                    )

                    await eventHub.publish(
                        .requestStart(
                            requestID: requestID,
                            method: urlRequest.httpMethod ?? "UNKNOWN",
                            url: urlRequest.url?.absoluteString ?? "",
                            retryIndex: 0
                        ),
                        requestID: requestID,
                        observers: configuration.eventObservers
                    )

                    let (bytes, response) = try await session.bytes(for: urlRequest, context: context)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NetworkError.nonHTTPResponse(response)
                    }
                    guard configuration.acceptableStatusCodes.contains(httpResponse.statusCode) else {
                        throw NetworkError.statusCode(
                            Response(
                                statusCode: httpResponse.statusCode,
                                data: Data(),
                                request: urlRequest,
                                response: httpResponse
                            )
                        )
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let output = try request.decode(line: line) {
                            continuation.yield(output)
                        }
                    }
                    await eventHub.finish(requestID: requestID)
                    await inFlight.deregister(id: requestID)
                    continuation.finish()
                } catch {
                    await eventHub.finish(requestID: requestID)
                    await inFlight.deregister(id: requestID)
                    if NetworkError.isCancellation(error) {
                        continuation.finish(throwing: NetworkError.cancelled)
                    } else if let networkError = error as? NetworkError {
                        continuation.finish(throwing: networkError)
                    } else {
                        continuation.finish(throwing: NetworkError.underlying(SendableUnderlyingError(error), nil))
                    }
                }
            }

            // Register out-of-band; if cancelAll fires before this completes,
            // the next loop iteration's Task.checkCancellation() still triggers
            // because the Task inherits cancellation when we call work.cancel().
            Task { await inFlight.register(id: requestID, cancelHandler: { work.cancel() }) }

            continuation.onTermination = { _ in
                work.cancel()
            }
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
        await inFlight.cancelAll()
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
        // Wrap the work in an unstructured Task so cancelAll() can reach it
        // without the call site having to track individual Task handles.
        // Outer-task cancellation is forwarded via withTaskCancellationHandler.
        let work = Task<D.APIResponse, Error> { [eventHub, configuration, session, requestBuilder] in
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
        await inFlight.register(id: requestID, cancelHandler: { work.cancel() })

        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            await inFlight.deregister(id: requestID)
            return result
        } catch {
            await inFlight.deregister(id: requestID)
            throw error
        }
    }
}
