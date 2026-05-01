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
///
/// > Important: `LowLevelNetworkClient` is exposed through
/// > `@_spi(GeneratedClientSupport)` and is **best-effort**: it is not part of
/// > the default SwiftPM import contract, it is not ABI-stable across releases,
/// > and it may evolve in any minor release without a deprecation window. See
/// > `API_STABILITY.md` and `Examples/GeneratedClientRecipe` for the supported
/// > usage shape.
@_spi(GeneratedClientSupport) public protocol LowLevelNetworkClient: Sendable {
    /// Executes a standard typed request through the low-level execution
    /// pipeline.
    ///
    /// `perform(_:tag:)` is primarily intended for framework authors and
    /// policy layers that already opt into `@_spi(GeneratedClientSupport)` to
    /// adapt richer request contracts into `InnoNetwork`. Application
    /// integrations should normally prefer ``NetworkClient/request(_:)``.
    ///
    /// - Parameters:
    ///   - request: The typed request definition to execute through the
    ///     low-level pipeline.
    ///   - tag: Optional ``CancellationTag`` for grouped cancellation; pass
    ///     `nil` when the request should not be reachable through
    ///     ``DefaultNetworkClient/cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    func perform<T: APIDefinition>(_ request: T, tag: CancellationTag?) async throws -> T.APIResponse
    /// Executes a custom request executable through the low-level execution pipeline.
    ///
    /// This overload exists for higher-level networking layers that want to control
    /// request serialization and decoding while still delegating execution, retry,
    /// and observability to `InnoNetwork`.
    ///
    /// - Parameters:
    ///   - executable: The custom executable that owns request metadata,
    ///     payload creation, and response decoding.
    ///   - tag: Optional ``CancellationTag`` for grouped cancellation; pass
    ///     `nil` when the request should not be reachable through
    ///     ``DefaultNetworkClient/cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    func perform<D: SingleRequestExecutable>(executable: D, tag: CancellationTag?) async throws -> D.APIResponse
}

@_spi(GeneratedClientSupport) public extension LowLevelNetworkClient {
    /// Convenience overload that calls ``perform(_:tag:)`` with `tag = nil`.
    func perform<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(request, tag: nil)
    }

    /// Convenience overload that calls ``perform(executable:tag:)`` with
    /// `tag = nil`.
    func perform<D: SingleRequestExecutable>(executable: D) async throws -> D.APIResponse {
        try await perform(executable: executable, tag: nil)
    }
}


package struct StreamingResumeState: Sendable {
    package private(set) var lastSeenEventID: String?
    private var perAttemptSeenNewCursor = false

    package init() {}

    package mutating func beginAttempt() {
        perAttemptSeenNewCursor = false
    }

    package mutating func observe(eventID: String?) {
        guard let eventID else { return }
        lastSeenEventID = eventID
        perAttemptSeenNewCursor = true
    }

    package func canResume(maxAttempts: Int, completedResumeAttempts: Int) -> Bool {
        maxAttempts > 0
            && completedResumeAttempts < maxAttempts
            && lastSeenEventID != nil
            && perAttemptSeenNewCursor
    }
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
public final class DefaultNetworkClient: NetworkClient, Sendable {
    private let configuration: NetworkConfiguration
    private let session: URLSessionProtocol
    private let requestBuilder = RequestBuilder()
    private let eventHub: NetworkEventHub
    private let inFlight = InFlightRegistry()
    private let executionRuntime: RequestExecutionRuntime

    public init(
        configuration: NetworkConfiguration,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.configuration = configuration
        self.session = session
        self.executionRuntime = RequestExecutionRuntime(configuration: configuration, inFlight: inFlight)
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
        // Streaming responses must not silently drop server-emitted events
        // (lost SSE frames, JSON-lines records, etc.), so the policy is
        // explicit `.unbounded`. Callers that observe back-pressure should
        // consume on a hot path or apply downstream batching themselves.
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let requestID = UUID()
            let inFlight = self.inFlight
            let configuration = self.configuration
            let executionRuntime = self.executionRuntime
            let executor = StreamingExecutor(session: self.session, eventHub: self.eventHub)
            let startGate = TaskStartGate()

            let work = Task<Void, Never> {
                await startGate.wait()
                await executor.run(
                    request: request,
                    requestID: requestID,
                    configuration: configuration,
                    executionRuntime: executionRuntime,
                    inFlight: inFlight,
                    continuation: continuation
                )
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

    /// Cancels every in-flight request that was dispatched with the supplied
    /// ``CancellationTag``. Untagged requests, and requests with a different
    /// tag, are left alone.
    ///
    /// Use this when a screen, feature, or user session goes away and the
    /// caller wants to drop only its own requests without disturbing the rest
    /// of the app.
    public func cancelAll(matching tag: CancellationTag) async {
        inFlight.cancelAll(matching: tag)
    }

    public func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        return try await perform(request, tag: nil)
    }

    /// Executes a typed request and registers it under the supplied
    /// ``CancellationTag`` so it can later be cancelled with
    /// ``cancelAll(matching:)``.
    public func request<T: APIDefinition>(
        _ request: T,
        tag: CancellationTag?
    ) async throws -> T.APIResponse {
        try await perform(request, tag: tag)
    }

    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(executable: MultipartSingleRequestExecutable(base: request), tag: nil)
    }

    /// Executes a multipart upload and registers it under the supplied
    /// ``CancellationTag``.
    public func upload<T: MultipartAPIDefinition>(
        _ request: T,
        tag: CancellationTag?
    ) async throws -> T.APIResponse {
        try await perform(executable: MultipartSingleRequestExecutable(base: request), tag: tag)
    }

    /// Low-level typed execution entry point for standard ``APIDefinition`` requests.
    ///
    /// Use this when you need to make the execution pipeline itself the dependency
    /// boundary. Most app integrations should still prefer ``request(_:)``.
    ///
    /// - Parameters:
    ///   - request: The typed request definition to execute through the
    ///     low-level pipeline.
    ///   - tag: Optional ``CancellationTag`` so the request is reachable via
    ///     ``cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    @_spi(GeneratedClientSupport) public func perform<T: APIDefinition>(
        _ request: T,
        tag: CancellationTag? = nil
    ) async throws -> T.APIResponse {
        try await perform(executable: APISingleRequestExecutable(base: request), tag: tag)
    }

    /// Low-level typed execution entry point for custom ``SingleRequestExecutable`` values.
    ///
    /// This API is intended for upper networking layers that need full control over
    /// serialization and decoding but still want `InnoNetwork` to own request
    /// building, retry coordination, trust handling, and observability.
    ///
    /// - Parameters:
    ///   - executable: The custom executable that owns request metadata,
    ///     payload creation, and response decoding.
    ///   - tag: Optional ``CancellationTag`` so the request is reachable via
    ///     ``cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    @_spi(GeneratedClientSupport)
    public func perform<D: SingleRequestExecutable>(
        executable: D,
        tag: CancellationTag? = nil
    ) async throws -> D.APIResponse {
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
                    runtime: executionRuntime,
                    retryIndex: retryIndex,
                    requestID: requestID
                )
            }
        }
        inFlight.register(id: requestID, tag: tag, cancelHandler: { work.cancel() })
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

@_spi(GeneratedClientSupport) extension DefaultNetworkClient: LowLevelNetworkClient {}
