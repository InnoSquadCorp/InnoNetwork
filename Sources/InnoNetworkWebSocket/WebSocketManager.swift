import Foundation
import InnoNetwork
import OSLog

public enum WebSocketEvent: Sendable {
    case connected(String?)
    case disconnected(WebSocketError?)
    case message(Data)
    case string(String)
    /// Emitted just before a ping frame is issued, from either the heartbeat
    /// loop or ``WebSocketManager/ping(_:)``.
    ///
    /// A successful ping is followed by `.pong`. Public
    /// ``WebSocketManager/ping(_:)`` failures publish a paired `.error(_:)`
    /// before throwing. Heartbeat timeouts publish `.error(.pingTimeout)`,
    /// while non-timeout transport failures surface through the surrounding
    /// disconnect / error lifecycle.
    ///
    /// The associated ``WebSocketPingContext`` carries the attempt number
    /// within the current connection plus a dispatch timestamp, letting
    /// consumers compute per-cycle RTT without maintaining their own
    /// bookkeeping.
    case ping(WebSocketPingContext)
    /// Emitted when a ping frame's paired pong is received.
    ///
    /// The associated ``WebSocketPongContext`` carries the matching
    /// ``WebSocketPingContext/attemptNumber`` and the library-computed
    /// `roundTrip: Duration`. Consumers can observe this either through the
    /// event stream (pattern-bind the context) or through the convenience
    /// callback ``WebSocketManager/setOnPongHandler(_:)``; **both paths
    /// receive the same `WebSocketPongContext` value** at the same logical
    /// point in the heartbeat / public-ping cycle.
    case pong(WebSocketPongContext)
    case error(WebSocketError)
    /// Emitted when a `send(_:message:)` / `send(_:string:)` call is dropped
    /// because the per-task in-flight count is at
    /// ``WebSocketConfiguration/sendQueueLimit`` and the configured
    /// ``WebSocketSendOverflowPolicy`` is ``WebSocketSendOverflowPolicy/dropNewest``.
    /// Drops do not throw; observers can use this event to surface back-
    /// pressure or report telemetry.
    case sendDropped(limit: Int)
}


/// Metadata that accompanies every ``WebSocketEvent/ping(_:)`` emission.
///
/// - ``attemptNumber`` is a monotonically increasing counter that starts at
///   1 for the first ping of a given connection (heartbeat or public
///   ``WebSocketManager/ping(_:)``) and resets to 0 when a new connection
///   becomes ready or the task is manually reset. Use it to correlate
///   `.ping(_:)` with the paired `.pong` or `.error(_:)` that follow.
/// - ``dispatchedAt`` is captured with `ContinuousClock.now` immediately
///   before the `.ping` event is published. Consumers typically pair it with
///   a `ContinuousClock.now` snapshot at `.pong` receipt to compute RTT.
///
/// This struct is designed to gain fields in minor releases without breaking
/// existing consumers — the public initializer is package-scoped so the
/// library controls construction.
public struct WebSocketPingContext: Sendable, Hashable {
    /// Sequence number of this ping attempt within the current connection.
    /// 1-indexed; resets when a new connection becomes ready or on task reset.
    public let attemptNumber: Int

    /// `ContinuousClock.now` snapshot at the moment `.ping(_:)` is
    /// published, captured immediately before the actual ping frame is
    /// dispatched.
    public let dispatchedAt: ContinuousClock.Instant

    package init(attemptNumber: Int, dispatchedAt: ContinuousClock.Instant) {
        self.attemptNumber = attemptNumber
        self.dispatchedAt = dispatchedAt
    }
}


/// Metadata delivered to ``WebSocketManager/setOnPongHandler(_:)`` for each
/// successful pong observation.
///
/// - ``attemptNumber`` matches the ``WebSocketPingContext/attemptNumber``
///   of the paired ping, so consumers can correlate ping/pong pairs
///   without bookkeeping a timestamp map keyed on the ping dispatch time.
/// - ``roundTrip`` is the library-computed duration between the
///   `.ping(_:)` event emission and the pong handler callback. It is measured
///   as `ContinuousClock.now - pingContext.dispatchedAt` just before the
///   `.pong` event is published, so it includes the library's own ping-send +
///   pong-handler dispatch but excludes consumer-side scheduler jitter.
///   Heartbeat scheduling still uses the injected `InnoNetworkClock`; RTT
///   measurement always uses wall-clock `ContinuousClock`.
///
/// This struct is designed to gain fields in minor releases without
/// breaking existing consumers — the public initializer is package-scoped
/// so the library controls construction.
public struct WebSocketPongContext: Sendable, Hashable {
    /// Sequence number of the paired ping attempt. Matches the
    /// `.ping(_:)` event's ``WebSocketPingContext/attemptNumber``.
    public let attemptNumber: Int

    /// Elapsed time between the paired `.ping(_:)` dispatch and this
    /// pong-handler callback, computed as
    /// `ContinuousClock.now - pingContext.dispatchedAt`. This value is not
    /// derived from the injected heartbeat scheduling clock.
    public let roundTrip: Duration

    package init(attemptNumber: Int, roundTrip: Duration) {
        self.attemptNumber = attemptNumber
        self.roundTrip = roundTrip
    }
}

public struct WebSocketEventSubscription: Hashable, Sendable {
    fileprivate let taskId: String
    fileprivate let listenerID: UUID

    public var id: UUID { listenerID }
}

enum WebSocketInternalError: Error {
    case pingTimeout
}

private let webSocketManagerLogger = Logger(
    subsystem: "com.innosquad.innonetwork",
    category: "websocket-manager"
)

private let closeHandshakeTimeout: Duration = .seconds(3)


public final class WebSocketManager: NSObject, Sendable {
    public static let shared = WebSocketManager()

    private let configuration: WebSocketConfiguration
    private let session: any WebSocketURLSession
    private let delegate: WebSocketSessionDelegate

    package let runtimeRegistry = WebSocketRuntimeRegistry()
    private let eventHub: TaskEventHub<WebSocketEvent>

    private var receiveLoop: WebSocketReceiveLoop {
        WebSocketReceiveLoop(
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    private var connectionCoordinator: WebSocketConnectionCoordinator {
        WebSocketConnectionCoordinator(
            configuration: configuration,
            session: session,
            runtimeRegistry: runtimeRegistry,
            receiveLoop: receiveLoop
        )
    }

    private var reconnectCoordinator: WebSocketReconnectCoordinator {
        WebSocketReconnectCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry
        )
    }

    private var heartbeatCoordinator: WebSocketHeartbeatCoordinator {
        WebSocketHeartbeatCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    public convenience init(configuration: WebSocketConfiguration = .default) {
        let callbacks = WebSocketSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        let delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore
        )

        let sessionConfig = configuration.makeURLSessionConfiguration()
        let urlSession = URLSession(
            configuration: sessionConfig,
            delegate: delegate,
            delegateQueue: nil
        )

        self.init(
            configuration: configuration,
            urlSession: urlSession,
            delegate: delegate,
            callbacks: callbacks
        )
    }

    /// Package-level designated initializer allowing tests to inject a
    /// `WebSocketURLSession` stub alongside a delegate that wires error/close
    /// callbacks.
    package init(
        configuration: WebSocketConfiguration,
        urlSession: any WebSocketURLSession,
        delegate: WebSocketSessionDelegate,
        callbacks: WebSocketSessionDelegateCallbacks
    ) {
        self.configuration = configuration
        self.delegate = delegate
        self.eventHub = TaskEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .webSocketTask
        )
        self.session = urlSession

        super.init()

        callbacks.setHandlers(
            onConnected: { [weak self] taskIdentifier, protocolName in
                self?.handleConnected(taskIdentifier: taskIdentifier, protocolName: protocolName)
            },
            onDisconnected: { [weak self] taskIdentifier, closeCode, reason in
                self?.handleDisconnected(
                    taskIdentifier: taskIdentifier,
                    closeCode: closeCode,
                    reason: reason
                )
            },
            onError: { [weak self] taskIdentifier, error, statusCode in
                self?.handleSessionError(
                    taskIdentifier: taskIdentifier,
                    error: error,
                    statusCode: statusCode
                )
            }
        )
    }

    /// Sets a callback that runs when a socket connects.
    ///
    /// - Parameter callback: Optional async handler receiving the connected task and negotiated
    ///   subprotocol (`nil` when the server does not negotiate one).
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    public func setOnConnectedHandler(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) async {
        await runtimeRegistry.setOnConnected(callback)
    }

    /// Sets a callback that runs when a socket disconnects.
    ///
    /// - Parameter callback: Optional async handler receiving the disconnected task and optional
    ///   disconnect error detail.
    /// - Note: The handler is invoked after task state is transitioned to `.disconnected`.
    public func setOnDisconnectedHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) async
    {
        await runtimeRegistry.setOnDisconnected(callback)
    }

    /// Sets a callback that runs when binary message data is received.
    ///
    /// - Parameter callback: Optional async handler receiving the source task and message payload.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    public func setOnMessageHandler(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) async {
        await runtimeRegistry.setOnMessage(callback)
    }

    /// Sets a callback that runs when a text message is received.
    ///
    /// - Parameter callback: Optional async handler receiving the source task and UTF-8 string.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    public func setOnStringHandler(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) async {
        await runtimeRegistry.setOnString(callback)
    }

    /// Sets a callback that runs when an operational WebSocket error occurs.
    ///
    /// - Parameter callback: Optional async handler receiving the task and mapped `WebSocketError`.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    public func setOnErrorHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) async {
        await runtimeRegistry.setOnError(callback)
    }

    /// Sets a callback that runs when a ping's paired pong is observed.
    ///
    /// - Parameter callback: Optional async handler receiving the task and a
    ///   ``WebSocketPongContext`` carrying the ping attempt number and
    ///   library-computed round-trip duration.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    /// - Note: On success, the handler runs immediately before the paired `.pong` event is published.
    public func setOnPongHandler(_ callback: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?) async {
        await runtimeRegistry.setOnPong(callback)
    }

    @discardableResult
    public func connect(url: URL, subprotocols: [String]? = nil) async -> WebSocketTask {
        let task = WebSocketTask(url: url, subprotocols: subprotocols)
        await runtimeRegistry.add(task)
        await startConnection(task)
        return task
    }

    public func disconnect(_ task: WebSocketTask, closeCode: WebSocketCloseCode = .normalClosure) async {
        let state = await task.state
        switch state {
        case .connected, .connecting, .reconnecting:
            break
        case .idle, .disconnecting, .disconnected, .failed:
            return
        }

        await task.setAutoReconnectEnabled(false)
        await runtimeRegistry.cancelHeartbeatTask(for: task.id)
        await runtimeRegistry.cancelReconnectTask(for: task.id)
        await runtimeRegistry.cancelMessageListenerTask(for: task.id)
        await task.updateState(.disconnecting)
        let disconnectError: WebSocketError? = makeManualDisconnectError(closeCode: closeCode)
        await task.beginManualDisconnect(error: disconnectError)

        if let urlTask = await runtimeRegistry.urlTask(for: task.id) {
            // URLSession demands its own close-code enum at the cancel() call,
            // so convert at the Foundation boundary.
            urlTask.cancel(with: closeCode.urlSessionCloseCode, reason: nil)
            let closeTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: closeHandshakeTimeout)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                await self?.handleCloseHandshakeTimeout(taskID: task.id, closeCode: closeCode)
            }
            await runtimeRegistry.setCloseHandshakeTask(closeTimeoutTask, for: task.id)
        } else {
            _ = await task.completeManualDisconnect()
            await finalizeDisconnect(
                task: task,
                closeCode: closeCode,
                disposition: .manual(closeCode),
                error: disconnectError
            )
            return
        }
    }

    public func disconnectAll(closeCode: WebSocketCloseCode = .normalClosure) async {
        for task in await runtimeRegistry.allTasks() {
            await disconnect(task, closeCode: closeCode)
        }
    }

    public func retry(_ task: WebSocketTask) async {
        let state = await task.state
        guard state == .failed || state == .disconnected else { return }
        await runtimeRegistry.add(task)
        await task.setAutoReconnectEnabled(true)
        await task.reset()
        await startConnection(task)
    }

    public func send(_ task: WebSocketTask, message: Data) async throws {
        try await sendGuarded(task: task) { urlTask in
            try await urlTask.send(.data(message))
        }
    }

    public func send(_ task: WebSocketTask, string: String) async throws {
        try await sendGuarded(task: task) { urlTask in
            try await urlTask.send(.string(string))
        }
    }

    /// Reserves a send slot under ``WebSocketConfiguration/sendQueueLimit``,
    /// dispatches the body, and releases the slot. Honours the configured
    /// ``WebSocketSendOverflowPolicy`` when the limit is exhausted.
    private func sendGuarded(
        task: WebSocketTask,
        _ body: @Sendable (any WebSocketURLTask) async throws -> Void
    ) async throws {
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else {
            throw WebSocketError.disconnected(nil)
        }

        let limit = configuration.sendQueueLimit
        let reserved = await task.tryReserveSendSlot(limit: limit)
        guard reserved else {
            switch configuration.sendQueueOverflowPolicy {
            case .fail:
                throw WebSocketError.sendQueueOverflow(limit: limit)
            case .dropNewest:
                await eventHub.publish(.sendDropped(limit: limit), for: task.id)
                return
            }
        }

        do {
            try await body(urlTask)
            await task.releaseSendSlot()
        } catch {
            await task.releaseSendSlot()
            throw error
        }
    }

    public func ping(_ task: WebSocketTask) async throws {
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else {
            throw WebSocketError.disconnected(nil)
        }
        let attempt = await task.incrementPingCounter()
        let context = WebSocketPingContext(attemptNumber: attempt, dispatchedAt: .now)
        await eventHub.publish(.ping(context), for: task.id)
        do {
            try await heartbeatCoordinator.sendPing(urlTask, timeout: configuration.pongTimeout)
            let pongContext = WebSocketPongContext(
                attemptNumber: context.attemptNumber,
                roundTrip: ContinuousClock.now - context.dispatchedAt
            )
            await publishPong(task: task, context: pongContext)
        } catch {
            let wsError = mapWebSocketError(error)
            await eventHub.publish(.error(wsError), for: task.id)
            throw wsError
        }
    }

    public func task(withId id: String) async -> WebSocketTask? {
        await runtimeRegistry.task(withId: id)
    }

    public func allTasks() async -> [WebSocketTask] {
        await runtimeRegistry.allTasks()
    }

    public func activeTasks() async -> [WebSocketTask] {
        var result: [WebSocketTask] = []
        for task in await runtimeRegistry.allTasks() {
            let state = await task.state
            if state == .connected || state == .connecting || state == .reconnecting {
                result.append(task)
            }
        }
        return result
    }

    func runtimeTaskIdentifier(for task: WebSocketTask) async -> Int? {
        await runtimeRegistry.taskIdentifier(for: task.id)
    }

    func listenerCount(for task: WebSocketTask) async -> Int {
        await eventHub.listenerCount(taskID: task.id)
    }

    /// Adds an event listener for a socket task.
    ///
    /// - Parameters:
    ///   - task: Target task to observe.
    ///   - listener: Listener invoked for each emitted `WebSocketEvent`.
    /// - Returns: A subscription token used to remove the listener later.
    /// - Note: Listener callbacks are invoked from an internal async context, not the main actor.
    public func addEventListener(
        for task: WebSocketTask,
        listener: @escaping @Sendable (WebSocketEvent) async -> Void
    ) async -> WebSocketEventSubscription {
        let listenerID = await eventHub.addListener(taskID: task.id, listener: listener)
        return WebSocketEventSubscription(taskId: task.id, listenerID: listenerID)
    }

    /// Removes an event listener using its subscription token.
    ///
    /// - Parameter subscription: Token returned by `addEventListener(for:listener:)`.
    public func removeEventListener(_ subscription: WebSocketEventSubscription) async {
        await eventHub.removeListener(taskID: subscription.taskId, listenerID: subscription.listenerID)
    }

    /// Creates an `AsyncStream` of WebSocket events for a task.
    ///
    /// - Parameter task: Target task to observe.
    /// - Returns: Event stream that remains active until iteration stops or terminal cleanup occurs.
    /// - Note: Listener registration completes before this method returns, so no initial events are lost.
    public func events(for task: WebSocketTask) async -> AsyncStream<WebSocketEvent> {
        await eventHub.stream(for: task.id)
    }

    private func startConnection(_ task: WebSocketTask) async {
        await task.advanceConnectionGeneration()
        await task.setAutoReconnectEnabled(true)
        await task.updateState(.connecting)
        await connectionCoordinator.startConnection(task) { [weak self] taskIdentifier, error in
            self?.handleError(taskIdentifier: taskIdentifier, error: error)
        }
    }

    private func publishPong(task: WebSocketTask, context: WebSocketPongContext) async {
        await runtimeRegistry.onPong?(task, context)
        await eventHub.publish(.pong(context), for: task.id)
    }

    func handleConnected(taskIdentifier: Int, protocolName: String?) {
        Task {
            guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }
            let state = await task.state
            let autoReconnectEnabled = await task.autoReconnectEnabled
            if state == .disconnecting || state == .disconnected || !autoReconnectEnabled {
                await runtimeRegistry.removeTaskRuntime(taskId: task.id)
                return
            }

            // Re-entering `.connected` from `.reconnecting` means a reconnect
            // attempt landed. Bump the cumulative successful counter before
            // resetting the per-cycle attempted counter.
            if state == .reconnecting {
                await task.incrementSuccessfulReconnectCount()
            }
            await task.resetAttemptedReconnectCount()
            await task.resetPingCounter()
            await task.setAutoReconnectEnabled(true)
            await task.setError(nil)
            await task.updateState(.connected)
            await heartbeatCoordinator.startHeartbeat(for: task) { [weak self] taskIdentifier in
                await self?.handleMappedError(taskIdentifier: taskIdentifier, error: .pingTimeout)
            }
            await runtimeRegistry.onConnected?(task, protocolName)
            await eventHub.publish(.connected(protocolName), for: task.id)
        }
    }

    func handleDisconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?) {
        Task {
            guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }
            let previousState = await task.state
            if await task.awaitingCloseHandshake {
                let manualError = await task.completeManualDisconnect()
                await runtimeRegistry.cancelCloseHandshakeTask(for: task.id)
                await finalizeDisconnect(
                    task: task,
                    closeCode: closeCode,
                    disposition: .manual(closeCode),
                    error: manualError
                )
                return
            }

            if previousState == .disconnecting || previousState == .disconnected {
                return
            }

            let disposition = WebSocketCloseDisposition.classifyPeerClose(
                closeCode,
                reason: reason
            )
            let error = makeDisconnectedError(closeDisposition: disposition)
            await task.updateState(.disconnected)
            await task.setCloseCode(closeCode)
            await task.setCloseDisposition(disposition)
            await task.setError(error)
            let terminalGeneration = await prepareTerminalRuntimeCleanup(for: task)
            await runtimeRegistry.onDisconnected?(task, error)
            await eventHub.publishAndWaitForDelivery(.disconnected(error), for: task.id)
            guard await isCurrentConnection(task, generation: terminalGeneration) else { return }

            let reconnectAction = await reconnectCoordinator.reconnectAction(
                task: task,
                closeDisposition: disposition,
                previousState: previousState
            )
            switch reconnectAction {
            case .retry:
                await reconnectCoordinator.attemptReconnect(task: task) { [weak self] task in
                    await self?.startReconnecting(task)
                }
                return
            case .exceeded:
                await task.updateState(.failed)
                await task.setError(.maxReconnectAttemptsExceeded)
                await runtimeRegistry.onError?(task, .maxReconnectAttemptsExceeded)
                await eventHub.publishAndWaitForDelivery(.error(.maxReconnectAttemptsExceeded), for: task.id)
            case .terminal:
                break
            }

            await finishTerminalTaskIfCurrent(task, generation: terminalGeneration)
        }
    }

    func handleError(taskIdentifier: Int, error: Error) {
        let wsError = mapWebSocketError(error)
        Task {
            if case .cancelled = wsError,
                let task = await runtimeRegistry.webSocketTask(for: taskIdentifier),
                await task.isClientInitiatedCloseFlow()
            {
                return
            }
            if case .cancelled = wsError {
                return
            }
            await handleMappedError(taskIdentifier: taskIdentifier, error: wsError)
        }
    }

    func handleSessionError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int? = nil) {
        Task {
            if isCancelledTransportError(error),
                let task = await runtimeRegistry.webSocketTask(for: taskIdentifier),
                await task.isClientInitiatedCloseFlow()
            {
                return
            }

            guard !isCancelledTransportError(error) else { return }
            guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }

            let state = await task.state
            if state == .connecting || state == .reconnecting {
                let disposition = WebSocketCloseDisposition.classifyHandshake(
                    statusCode: statusCode,
                    error: error
                )
                await handleFailure(
                    task: task,
                    closeDisposition: disposition,
                    previousState: state
                )
                return
            }

            let wsError: WebSocketError = isTimeoutTransportError(error) ? .pingTimeout : .connectionFailed(error)
            await handleFailure(task: task, closeDisposition: .transportFailure(wsError))
        }
    }

    private func mapWebSocketError(_ error: Error) -> WebSocketError {
        if let internalError = error as? WebSocketInternalError {
            switch internalError {
            case .pingTimeout:
                return .pingTimeout
            }
        }

        if let webSocketError = error as? WebSocketError {
            return webSocketError
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .pingTimeout
            default:
                return .connectionFailed(SendableUnderlyingError(error))
            }
        }

        return .connectionFailed(SendableUnderlyingError(error))
    }

    private func isCancelledTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    private func isTimeoutTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.timedOut.rawValue
    }

    private func handleMappedError(taskIdentifier: Int, error: WebSocketError) async {
        guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }
        await handleFailure(task: task, closeDisposition: .transportFailure(error))
    }

    private func handleFailure(
        task: WebSocketTask,
        closeDisposition: WebSocketCloseDisposition,
        previousState: WebSocketState? = nil
    ) async {
        let finalError = makeFailureError(closeDisposition: closeDisposition)
        let reconnectAction = await reconnectCoordinator.reconnectAction(
            task: task,
            closeDisposition: closeDisposition,
            previousState: previousState
        )
        // Record the classified disposition for consumer observation before
        // transitioning state, regardless of the reconnect decision.
        await task.setCloseDisposition(closeDisposition)

        switch reconnectAction {
        case .retry:
            await task.updateState(.reconnecting)
            await task.setError(finalError)
            let reconnectGeneration = await prepareTerminalRuntimeCleanup(for: task)
            await runtimeRegistry.onError?(task, finalError)
            await eventHub.publishAndWaitForDelivery(.error(finalError), for: task.id)
            guard await isCurrentConnection(task, generation: reconnectGeneration),
                await task.state == .reconnecting
            else { return }
            await reconnectCoordinator.attemptReconnect(task: task) { [weak self] task in
                await self?.startReconnecting(task)
            }
            return
        case .terminal:
            await task.updateState(.failed)
            await task.setError(finalError)
            let terminalGeneration = await prepareTerminalRuntimeCleanup(for: task)
            await runtimeRegistry.onError?(task, finalError)
            await eventHub.publishAndWaitForDelivery(.error(finalError), for: task.id)
            await finishTerminalTaskIfCurrent(task, generation: terminalGeneration)
        case .exceeded:
            let finalError: WebSocketError = .maxReconnectAttemptsExceeded
            await task.updateState(.failed)
            await task.setError(finalError)
            let terminalGeneration = await prepareTerminalRuntimeCleanup(for: task)
            await runtimeRegistry.onError?(task, finalError)
            await eventHub.publishAndWaitForDelivery(.error(finalError), for: task.id)
            await finishTerminalTaskIfCurrent(task, generation: terminalGeneration)
        }
    }

    private func startReconnecting(_ task: WebSocketTask) async {
        await task.updateState(.reconnecting)
        await startConnection(task)
    }

    private func finalizeDisconnect(
        task: WebSocketTask,
        closeCode: WebSocketCloseCode,
        disposition: WebSocketCloseDisposition,
        error: WebSocketError?
    ) async {
        await task.updateState(.disconnected)
        await task.setCloseCode(closeCode)
        await task.setCloseDisposition(disposition)
        await task.setError(error)
        let terminalGeneration = await prepareTerminalRuntimeCleanup(for: task)
        await runtimeRegistry.onDisconnected?(task, error)
        await eventHub.publishAndWaitForDelivery(.disconnected(error), for: task.id)
        await finishTerminalTaskIfCurrent(task, generation: terminalGeneration)
    }

    private func prepareTerminalRuntimeCleanup(for task: WebSocketTask) async -> Int {
        let generation = await task.connectionGeneration
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        return generation
    }

    private func finishTerminalTaskIfCurrent(_ task: WebSocketTask, generation: Int) async {
        guard await isCurrentTerminalTask(task, generation: generation) else { return }
        await eventHub.finish(taskID: task.id)
        guard await isCurrentTerminalTask(task, generation: generation) else { return }
        await runtimeRegistry.remove(task)
    }

    private func isCurrentTerminalTask(_ task: WebSocketTask, generation: Int) async -> Bool {
        guard await isCurrentConnection(task, generation: generation) else { return false }
        return await task.state.isTerminal
    }

    private func isCurrentConnection(_ task: WebSocketTask, generation: Int) async -> Bool {
        await task.connectionGeneration == generation
    }

    private func makeDisconnectedError(closeDisposition: WebSocketCloseDisposition) -> WebSocketError {
        switch closeDisposition {
        case .manual(let closeCode):
            return makeManualDisconnectError(closeCode: closeCode)
        case .peerNormal(let closeCode, let reason),
            .peerRetryable(let closeCode, let reason),
            .peerProtocolFailure(let closeCode, let reason),
            .peerApplicationFailure(let closeCode, let reason),
            .peerTerminal(let closeCode, let reason):
            guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .disconnected(nil)
            }
            return .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.CloseReason",
                    code: Int(closeCode.rawValue),
                    message: reason
                )
            )
        case .handshakeTimeout(let closeCode):
            return .disconnected(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.HandshakeTimeout",
                    code: Int(closeCode.rawValue),
                    message: "WebSocket close handshake timed out."
                )
            )
        case .handshakeUnauthorized,
            .handshakeForbidden,
            .handshakeServerUnavailable,
            .handshakeTransientNetwork,
            .handshakeTerminalHTTP:
            return makeFailureError(closeDisposition: closeDisposition)
        case .transportFailure(let error):
            return error
        }
    }

    private func makeFailureError(closeDisposition: WebSocketCloseDisposition) -> WebSocketError {
        switch closeDisposition {
        case .manual,
            .peerNormal,
            .peerRetryable,
            .peerProtocolFailure,
            .peerApplicationFailure,
            .peerTerminal,
            .handshakeTimeout:
            return makeDisconnectedError(closeDisposition: closeDisposition)
        case .handshakeUnauthorized(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with unauthorized response."
                )
            )
        case .handshakeForbidden(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with forbidden response."
                )
            )
        case .handshakeServerUnavailable(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with retryable server response."
                )
            )
        case .handshakeTransientNetwork(let error):
            return .connectionFailed(error)
        case .handshakeTerminalHTTP(let statusCode):
            return .connectionFailed(
                SendableUnderlyingError(
                    domain: "InnoNetworkWebSocket.Handshake",
                    code: statusCode,
                    message: "WebSocket handshake failed with terminal HTTP response."
                )
            )
        case .transportFailure(let error):
            return error
        }
    }

    private func makeManualDisconnectError(closeCode: WebSocketCloseCode) -> WebSocketError {
        .disconnected(
            SendableUnderlyingError(
                domain: "InnoNetworkWebSocket.ManualDisconnect",
                code: Int(closeCode.rawValue),
                message: "Client initiated disconnect."
            )
        )
    }

    private func handleCloseHandshakeTimeout(
        taskID: String,
        closeCode: WebSocketCloseCode
    ) async {
        guard let task = await runtimeRegistry.task(withId: taskID) else { return }
        guard await task.awaitingCloseHandshake else { return }

        await runtimeRegistry.clearCloseHandshakeTask(for: taskID)
        await task.clearManualDisconnectState()
        if let urlTask = await runtimeRegistry.urlTask(for: taskID) {
            urlTask.cancel()
        }
        let disposition: WebSocketCloseDisposition = .handshakeTimeout(closeCode)
        let finalError = makeDisconnectedError(
            closeDisposition: .handshakeTimeout(closeCode)
        )
        await finalizeDisconnect(
            task: task,
            closeCode: closeCode,
            disposition: disposition,
            error: finalError
        )
    }

    static func shouldReconnect(currentState: WebSocketState, autoReconnectEnabled: Bool) -> Bool {
        guard autoReconnectEnabled else { return false }
        switch currentState {
        case .failed, .disconnected, .reconnecting:
            return true
        case .idle, .connecting, .connected, .disconnecting:
            return false
        }
    }

    static func shouldRetryReconnect(after reconnectCount: Int, maxReconnectAttempts: Int) -> Bool {
        reconnectCount <= maxReconnectAttempts
    }

    public func handleBackgroundSessionCompletion(_ identifier: String, completion: @escaping @Sendable () -> Void) {
        // WebSocketManager does not own background URLSession processing.
        // `identifier` is accepted for API compatibility and intentionally completed immediately.
        webSocketManagerLogger.debug(
            "Ignoring background completion identifier for WebSocket runtime: \(identifier, privacy: .public)")
        completion()
    }
}
