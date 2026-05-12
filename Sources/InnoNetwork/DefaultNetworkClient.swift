import Foundation

public protocol NetworkClient: Sendable {
    /// Executes a standard typed request modeled with ``APIDefinition``.
    ///
    /// Prefer this entry point for normal request/response APIs.
    ///
    /// - Parameter request: The typed request definition to execute.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` produced while encoding, sending,
    ///   validating, or decoding the request. Foreign errors (e.g. raw
    ///   `URLError`, `CancellationError`) are mapped to the closest
    ///   ``NetworkError`` case at the client boundary.
    func request<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse

    /// Executes a typed request and registers it under the supplied
    /// ``CancellationTag`` so it can later be cancelled together with other
    /// requests bearing the same tag (typically via
    /// ``DefaultNetworkClient/cancelAll(matching:)``).
    ///
    /// Conformers must implement this overload explicitly. A tag-aware call
    /// that silently falls back to ``request(_:)`` would make grouped
    /// cancellation appear to succeed while leaving the work unreachable from
    /// the tag registry.
    ///
    /// - Parameters:
    ///   - request: The typed request definition to execute.
    ///   - tag: Optional cancellation tag; pass `nil` for ungrouped requests.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` produced while encoding, sending,
    ///   validating, or decoding the request.
    func request<T: APIDefinition>(_ request: T, tag: CancellationTag?) async throws(NetworkError) -> T.APIResponse

    /// Executes a multipart request modeled with ``MultipartAPIDefinition``.
    ///
    /// Prefer this entry point for upload-style integrations.
    ///
    /// - Parameter request: The multipart request definition to execute.
    /// - Returns: The decoded `APIResponse` produced by the multipart request.
    /// - Throws: A ``NetworkError`` produced while building, sending,
    ///   validating, or decoding the multipart request.
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse

    /// Executes a multipart upload and registers it under the supplied
    /// ``CancellationTag``. See ``request(_:tag:)`` for semantics.
    ///
    /// Conformers must implement this overload explicitly; see
    /// ``request(_:tag:)`` for the grouped-cancellation contract.
    func upload<T: MultipartAPIDefinition>(_ request: T, tag: CancellationTag?) async throws(NetworkError)
        -> T.APIResponse
}

extension NetworkClient {
    /// Default forwarder that calls ``request(_:tag:)`` with `tag: nil`.
    ///
    /// Conformers that need explicit observation of ungrouped requests may
    /// override this overload, but most mocks and stubs only need to
    /// implement the tag-aware path. The forwarder eliminates the boiler-
    /// plate of mirroring two methods in every test double — there is no
    /// silent-fallback risk because the implementation explicitly passes
    /// `tag: nil`, the same value the caller would have to pass anyway.
    public func request<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await self.request(request, tag: nil)
    }

    /// Default forwarder that calls ``upload(_:tag:)`` with `tag: nil`. See
    /// ``request(_:)`` for the rationale.
    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await self.upload(request, tag: nil)
    }
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

    package mutating func rejectEventID() {
        lastSeenEventID = nil
        perAttemptSeenNewCursor = false
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
    package let inFlight = InFlightRegistry()
    private let executionRuntime: RequestExecutionRuntime

    /// Creates a client backed by the given URL session.
    ///
    /// - Parameters:
    ///   - configuration: The ``NetworkConfiguration`` describing the
    ///     base URL, interceptors, retry policy, and observability hooks.
    ///   - session: The URL session that issues requests. Defaults to
    ///     ``URLSession/shared`` for ergonomic prototyping.
    ///
    /// > Warning: The default of ``URLSession/shared`` is convenient but has
    /// > three production caveats. Inject an explicit `URLSession` when any of
    /// > them matters to you:
    /// >
    /// > 1. **Shared cookie / credential storage.** `URLSession.shared` uses
    /// >    ``HTTPCookieStorage/shared`` and ``URLCredentialStorage/shared``,
    /// >    so any other SDK in the process (analytics, auth, push) sees the
    /// >    same cookie jar. For app-scoped or isolated stores, build a
    /// >    session with a dedicated `URLSessionConfiguration`.
    /// > 2. **No session-owned delegate or custom configuration.**
    /// >    `URLSession.shared` cannot be constructed with a custom
    /// >    `URLSessionConfiguration` or session delegate. InnoNetwork still
    /// >    installs per-task delegates for requests executed through this client,
    /// >    so configured trust evaluation, task metrics, and redirect policy
    /// >    apply on that path. Use an explicit session when you need
    /// >    session-wide delegate behavior or configuration-owned state.
    /// > 3. **Configuration drift.** `URLSessionConfiguration`-only choices
    /// >    such as HTTP/3 opt-in, cookie storage, proxy settings, and TLS
    /// >    protocol bounds are owned by the session. The shared session cannot
    /// >    inherit those choices from ``NetworkConfiguration``.
    /// >
    /// > Recommended explicit form:
    /// >
    /// > ```swift
    /// > let urlConfig = URLSessionConfiguration.ephemeral // isolated in-memory storage
    /// > urlConfig.timeoutIntervalForRequest = 30
    /// > let session = URLSession(
    /// >     configuration: urlConfig,
    /// >     delegate: nil,
    /// >     delegateQueue: nil
    /// > )
    /// > let client = DefaultNetworkClient(
    /// >     configuration: myAPI,
    /// >     session: session
    /// > )
    /// > ```
    public init(
        configuration: NetworkConfiguration,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.configuration = configuration
        self.session = session
        self.executionRuntime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: inFlight,
            clock: SystemClock()
        )
        self.eventHub = NetworkEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .networkRequest
        )
    }

    package init(
        configuration: NetworkConfiguration,
        session: URLSessionProtocol = URLSession.shared,
        clock: any InnoNetworkClock
    ) {
        self.configuration = configuration
        self.session = session
        self.executionRuntime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: inFlight,
            clock: clock
        )
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
        stream(request, bufferingPolicy: .unbounded)
    }

    /// Subscribes to a streaming endpoint with an explicit output buffering policy.
    ///
    /// Use the default ``stream(_:)`` for lossless delivery. Pick a bounded
    /// ``StreamingBufferingPolicy`` only when the stream can tolerate dropped
    /// decoded outputs and capped memory is more important than replaying
    /// every server-emitted line. Bounded buffering is rejected when
    /// ``StreamingResumePolicy/lastEventID(maxAttempts:retryDelay:)`` is active
    /// because the resume cursor must not advance past values a slow consumer
    /// never received.
    public func stream<T: StreamingAPIDefinition>(
        _ request: T,
        bufferingPolicy: StreamingBufferingPolicy
    ) -> AsyncThrowingStream<T.Output, Error> {
        if let incompatibleBufferingError = Self.incompatibleStreamingBufferingError(
            resumePolicy: request.resumePolicy,
            bufferingPolicy: bufferingPolicy
        ) {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: incompatibleBufferingError)
            }
        }

        // Streaming responses must not silently drop server-emitted events
        // (lost SSE frames, JSON-lines records, etc.), so the policy is
        // explicit `.unbounded` by default. Bounded overloads are opt-in for
        // streams where capped memory is more important than lossless output.
        let asyncBufferingPolicy: AsyncThrowingStream<T.Output, Error>.Continuation.BufferingPolicy
        switch bufferingPolicy {
        case .unbounded:
            asyncBufferingPolicy = .unbounded
        case .bufferingNewest(let limit):
            asyncBufferingPolicy = .bufferingNewest(max(1, limit))
        case .bufferingOldest(let limit):
            asyncBufferingPolicy = .bufferingOldest(max(1, limit))
        }

        return AsyncThrowingStream(bufferingPolicy: asyncBufferingPolicy) { continuation in
            let requestID = UUID()
            let inFlight = self.inFlight
            let configuration = self.configuration
            let executionRuntime = self.executionRuntime
            let executor = StreamingExecutor(session: self.session, eventHub: self.eventHub)
            let startGate = TaskStartGate()
            let generation = inFlight.generation()

            let work = Task<Void, Never> {
                guard await startGate.wait() else {
                    inFlight.deregister(id: requestID)
                    continuation.finish(throwing: NetworkError.cancelled)
                    return
                }
                // Match the non-streaming path: deregister from
                // ``InFlightRegistry`` when the executor finishes, no
                // matter whether the stream completed normally, errored,
                // or was cancelled. Without this, a streaming request
                // continues to occupy a slot in the registry after its
                // backing `Task` is gone, causing `cancelAll()` and the
                // tagged-cancel variants to hang on a stale handle.
                defer { inFlight.deregister(id: requestID) }
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
            inFlight.register(id: requestID, generation: generation, cancelHandler: { work.cancel() })
            startGate.open()
        }
    }

    private static func incompatibleStreamingBufferingError(
        resumePolicy: StreamingResumePolicy,
        bufferingPolicy: StreamingBufferingPolicy
    ) -> NetworkError? {
        // The compatibility decision now flows through the
        // ``StreamingResumeStrategy`` protocol so a future strategy
        // (byte-offset replay, NDJSON cursor windows) can answer the
        // same question without the executor learning a new case.
        // `StreamingResumePolicy` conforms to the protocol, so the call
        // site stays a single line of policy code.
        guard !resumePolicy.isCompatible(with: bufferingPolicy) else { return nil }
        return .configuration(
            reason: .invalidRequest(
                "StreamingResumePolicy requires unbounded output buffering for the configured resume strategy. Use stream(_:) or disable resume before choosing a bounded buffering policy."
            )
        )
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

    public func request<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(request, tag: nil)
        }
    }

    /// Executes a typed request and registers it under the supplied
    /// ``CancellationTag`` so it can later be cancelled with
    /// ``cancelAll(matching:)``.
    public func request<T: APIDefinition>(
        _ request: T,
        tag: CancellationTag?
    ) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(request, tag: tag)
        }
    }

    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(executable: MultipartSingleRequestExecutable(base: request), tag: nil)
        }
    }

    /// Executes a multipart upload and registers it under the supplied
    /// ``CancellationTag``.
    public func upload<T: MultipartAPIDefinition>(
        _ request: T,
        tag: CancellationTag?
    ) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(executable: MultipartSingleRequestExecutable(base: request), tag: tag)
        }
    }

    /// Funnels an untyped-throwing pipeline call into a typed
    /// `NetworkError` boundary. The retry coordinator already publishes
    /// `NetworkError` for every classified failure; this trap only catches
    /// foreign errors that bypass that normalization (e.g. raw
    /// `CancellationError` from a custom `RequestExecutionPolicy`) and
    /// maps them via ``NetworkError/mapTransportError(_:)``.
    @Sendable
    private static func mappingTransportErrors<Response: Sendable>(
        _ work: @Sendable () async throws -> Response
    ) async throws(NetworkError) -> Response {
        do {
            return try await work()
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.mapTransportError(error)
        }
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
        let generation = inFlight.generation(for: tag)
        // Wrap the work in an unstructured Task so cancelAll() can reach it
        // without the call site having to track individual Task handles.
        // Outer-task cancellation is forwarded via withTaskCancellationHandler.
        let work = Task<D.APIResponse, Error> { [eventHub, configuration, session, requestBuilder, executionRuntime] in
            guard await startGate.wait() else { throw NetworkError.cancelled }
            let retryCoordinator = RetryCoordinator(eventHub: eventHub, clock: executionRuntime.clock)
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
        inFlight.register(id: requestID, tag: tag, generation: generation, cancelHandler: { work.cancel() })
        defer { inFlight.deregister(id: requestID) }
        startGate.open()

        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

@_spi(GeneratedClientSupport) extension DefaultNetworkClient: LowLevelNetworkClient {}
