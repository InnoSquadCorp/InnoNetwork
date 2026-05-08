import Foundation
import InnoNetwork
import OSLog
import os

private let webSocketManagerLogger = Logger(
    subsystem: "com.innosquad.innonetwork",
    category: "websocket-manager"
)

/// Actor-isolated WebSocket connection manager.
///
/// 4.0.0 converts ``WebSocketManager`` from a `final class` (held
/// together with manual `OSAllocatedUnfairLock` synchronisation) into a
/// Swift actor. Callers must now `await` every public method:
///
/// ```swift
/// let manager = WebSocketManager(configuration: .default)
/// let task = await manager.connect(url: url)
/// for await event in await manager.events(for: task) { ... }
/// await manager.disconnect(task)
/// ```
///
/// The `URLSessionWebSocketDelegate` callback bridge is preserved as
/// nonisolated entry points (`handleConnected`, `handleDisconnected`,
/// `handleError`, `handleSessionError`) so synchronous URLSession
/// delegate-queue invocations keep working without a Task hop. Those
/// entry points only `yield` to the lossless `delegateEventContinuation`
/// stream, whose single consumer Task drains in arrival order back
/// through actor-isolated state.
public actor WebSocketManager {
    private let configuration: WebSocketConfiguration
    private let session: any WebSocketURLSession
    private let delegate: WebSocketSessionDelegate

    package let runtimeRegistry = WebSocketRuntimeRegistry()
    private let eventHub: TaskEventHub<WebSocketEvent>
    /// `OSAllocatedUnfairLock` is preserved here even after the actor
    /// conversion: the shutdown flag has to stay readable from the
    /// nonisolated ``deinit`` and from synchronous URLSession delegate
    /// callbacks, neither of which can hop onto the actor executor. The
    /// lock is internally `Sendable`, so a `nonisolated let` field is
    /// safe.
    nonisolated private let shutdownLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let invalidationBarrier: WebSocketInvalidationBarrier

    /// One-shot serialized event channel for URLSession delegate callbacks.
    /// `WebSocketSessionDelegate` invokes the four `handle*` entry points
    /// synchronously from arbitrary delegate-queue threads — without this
    /// channel each call would spawn its own `Task`, allowing
    /// `didOpen → didReceive → didClose` to interleave on the actor
    /// executor and (rarely) reorder the lifecycle observed by a single
    /// task. The single consumer Task drains in arrival order so each
    /// task identifier observes a strict FIFO of its own callbacks.
    nonisolated private let delegateEventContinuation: AsyncStream<DelegateEvent>.Continuation

    private enum DelegateEvent: Sendable {
        case connected(taskIdentifier: Int, protocolName: String?)
        case disconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?)
        case mappedError(taskIdentifier: Int, error: WebSocketError)
        case sessionError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int?)
    }

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
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    private var heartbeatCoordinator: WebSocketHeartbeatCoordinator {
        WebSocketHeartbeatCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    public init(configuration: WebSocketConfiguration = .default) {
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
        let invalidationBarrier = WebSocketInvalidationBarrier()
        self.invalidationBarrier = invalidationBarrier

        let (stream, continuation) = AsyncStream.makeStream(
            of: DelegateEvent.self,
            // Delegate events are reducer inputs, not best-effort UI
            // notifications. Dropping `didOpen`, `didClose`, or error
            // callbacks can leave task state, terminal cleanup, and
            // reconnect accounting inconsistent, so keep this bridge
            // lossless. User-facing event fan-out remains governed by
            // `TaskEventHub` delivery policy.
            bufferingPolicy: .unbounded
        )
        self.delegateEventContinuation = continuation

        callbacks.setInvalidationHandler { [invalidationBarrier] _ in
            Task {
                await invalidationBarrier.complete()
            }
        }

        // The consumer Task captures `self` weakly. Each loop iteration
        // drains exactly one event before awaiting the next, which is
        // what gives us the strict per-task FIFO ordering the prior
        // per-callback `Task` spawning could not guarantee. The Task is
        // intentionally not stored: `deinit` finishes the continuation,
        // the for-await loop exits, and the Task self-completes — no
        // retain cycle is possible because the closure captures `self`
        // weakly.
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.processDelegateEvent(event)
            }
        }

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

    deinit {
        delegateEventContinuation.finish()
        if !isShutdown {
            webSocketManagerLogger.fault(
                "WebSocketManager deinit reached without shutdown() — call shutdown() explicitly for bounded teardown"
            )
            session.invalidateAndCancel()
        }
    }

    private func processDelegateEvent(_ event: DelegateEvent) async {
        switch event {
        case .connected(let taskIdentifier, let protocolName):
            await processConnected(taskIdentifier: taskIdentifier, protocolName: protocolName)
        case .disconnected(let taskIdentifier, let closeCode, let reason):
            await processDisconnected(taskIdentifier: taskIdentifier, closeCode: closeCode, reason: reason)
        case .mappedError(let taskIdentifier, let error):
            await processMappedError(taskIdentifier: taskIdentifier, error: error)
        case .sessionError(let taskIdentifier, let error, let statusCode):
            await processSessionError(taskIdentifier: taskIdentifier, error: error, statusCode: statusCode)
        }
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
        guard !isShutdown else {
            let error = Self.managerShutdownError()
            _ = await task.applyLifecycleEvent(
                .failure(
                    generation: nil,
                    disposition: .transportFailure(error),
                    error: error
                ),
                context: .init(reconnectAction: .terminal)
            )
            return task
        }
        // The registry is the canonical guard: `add` refuses new tasks once
        // `shutdown()` has marked the registry as shutting down, so a concurrent
        // shutdown cannot leave this task as an orphan past the terminal sweep.
        guard await runtimeRegistry.add(task) else {
            await finishTaskBecauseManagerIsShutdown(task)
            return task
        }
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

        let disconnectError: WebSocketError? = makeManualDisconnectError(closeCode: closeCode)
        let transition = await task.applyLifecycleEvent(
            .manualDisconnect(closeCode: closeCode, error: disconnectError)
        )
        await executeLifecycleEffects(transition.effects, for: task)

        if await runtimeRegistry.urlTask(for: task.id) == nil,
            await task.awaitingCloseHandshake
        {
            let closeTransition = await task.applyLifecycleEvent(
                .didClose(
                    generation: await task.connectionGeneration,
                    closeCode: closeCode,
                    disposition: .manual(closeCode),
                    error: disconnectError
                )
            )
            await executeLifecycleEffects(closeTransition.effects, for: task)
        }
    }

    public func disconnectAll(closeCode: WebSocketCloseCode = .normalClosure) async {
        for task in await runtimeRegistry.allTasks() {
            await disconnect(task, closeCode: closeCode)
        }
    }

    /// Tears down the manager, cancels active sockets, finishes event streams,
    /// and invalidates the underlying URLSession.
    ///
    /// After `shutdown()` returns, the manager is terminal. Create a fresh
    /// instance for new socket work; diagnostic getters can still return their
    /// last-known values while terminal cleanup drains. Calling `shutdown()`
    /// multiple times is safe.
    public func shutdown() async {
        guard markShutdownIfNeeded() else {
            await invalidationBarrier.wait()
            return
        }

        delegateEventContinuation.finish()
        await runtimeRegistry.clearCallbacks()

        let shutdownError = Self.managerShutdownError()
        // Atomically flip the registry into a "no new tasks" state and capture
        // the live snapshot in a single actor hop. Any concurrent
        // `connect()`/`retry()` past this point will be refused at `add(_:)`
        // and routed through `finishTaskBecauseManagerIsShutdown`.
        for task in await runtimeRegistry.markShutdownStartedAndSnapshot() {
            let state = await task.state
            if !state.isTerminal {
                let transition = await task.applyLifecycleEvent(
                    .failure(
                        generation: await task.connectionGeneration,
                        disposition: .transportFailure(shutdownError),
                        error: shutdownError
                    ),
                    context: .init(reconnectAction: .terminal)
                )
                await executeLifecycleEffects(transition.effects, for: task)
            }
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
            await eventHub.finish(taskID: task.id)
            await runtimeRegistry.remove(task)
        }

        session.invalidateAndCancel()
        await invalidationBarrier.wait()
    }

    public func retry(_ task: WebSocketTask) async {
        guard !isShutdown else { return }
        let state = await task.state
        guard state == .failed || state == .disconnected else { return }
        // Reset before re-registering: this transitions the task out of its
        // terminal lifecycle state (`.failed`/`.disconnected`) into `.idle`,
        // which prevents an in-flight `finishTerminal` effect from racing with
        // the registry add and removing this task on its way to a new
        // connection. `reset()` itself emits no lifecycle effects, so it does
        // not interleave with the executor that is processing `.didClose`.
        await task.reset()
        // Registry refuses new tasks once shutdown has started, so this single
        // guard handles the shutdown-vs-retry race in the same way as
        // `connect(url:)`.
        guard await runtimeRegistry.add(task) else {
            await finishTaskBecauseManagerIsShutdown(task)
            return
        }
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
        let limit = configuration.sendQueueLimit
        guard let reserved = await task.tryReserveConnectedSendSlot(limit: limit) else {
            throw WebSocketError.disconnected(nil)
        }
        guard reserved else {
            switch configuration.sendQueueOverflowPolicy {
            case .fail:
                throw WebSocketError.sendQueueOverflow(limit: limit)
            case .dropNewest:
                await eventHub.publish(.sendDropped(limit: limit), for: task.id)
                return
            }
        }
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else {
            await task.releaseSendSlot()
            throw WebSocketError.disconnected(nil)
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
        guard let attempt = await task.nextConnectedPingAttempt() else {
            throw WebSocketError.disconnected(nil)
        }
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
            let wsError = Self.mapWebSocketError(error)
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
        guard !isShutdown else { return }
        let transition = await task.applyLifecycleEvent(.connect)
        await executeLifecycleEffects(transition.effects, for: task)
    }

    private func finishTaskBecauseManagerIsShutdown(_ task: WebSocketTask) async {
        let error = Self.managerShutdownError()
        let transition = await task.applyLifecycleEvent(
            .failure(
                generation: await task.connectionGeneration,
                disposition: .transportFailure(error),
                error: error
            ),
            context: .init(reconnectAction: .terminal)
        )
        await executeLifecycleEffects(transition.effects, for: task)
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finish(taskID: task.id)
        await runtimeRegistry.remove(task)
    }

    private func startTransportConnection(_ task: WebSocketTask) async {
        guard !isShutdown else { return }
        if configuration.permessageDeflateEnabled {
            await failUnsupportedURLSessionFeature(.permessageDeflate, for: task)
            return
        }
        await connectionCoordinator.startConnection(task) { [weak self] taskIdentifier, error in
            self?.handleError(taskIdentifier: taskIdentifier, error: error)
        }
    }

    private func failUnsupportedURLSessionFeature(
        _ feature: WebSocketProtocolFeature,
        for task: WebSocketTask
    ) async {
        let error = WebSocketError.unsupportedProtocolFeature(feature)
        let transition = await task.applyLifecycleEvent(
            .failure(
                generation: await task.connectionGeneration,
                disposition: .transportFailure(error),
                error: error
            ),
            context: .init(reconnectAction: .terminal)
        )
        await executeLifecycleEffects(transition.effects, for: task)
    }

    private func executeLifecycleEffects(
        _ effects: [WebSocketLifecycleEffect],
        for task: WebSocketTask
    ) async {
        for effect in effects {
            switch effect {
            case .startConnection(generation: _):
                await startTransportConnection(task)
            case .startHeartbeat:
                await heartbeatCoordinator.startHeartbeat(for: task) { [weak self] taskIdentifier in
                    await self?.handleMappedError(taskIdentifier: taskIdentifier, error: .pingTimeout)
                }
            case .cancelHeartbeat:
                await runtimeRegistry.cancelHeartbeatTask(for: task.id)
            case .cancelReconnect:
                await runtimeRegistry.cancelReconnectTask(for: task.id)
            case .cancelMessageListener:
                await runtimeRegistry.cancelMessageListenerTask(for: task.id)
            case .cleanupRuntime:
                await runtimeRegistry.removeTaskRuntime(taskId: task.id)
            case .scheduleCloseTimeout(let closeCode):
                await scheduleCloseHandshakeTimeout(for: task, closeCode: closeCode)
            case .cancelCloseTimeout:
                await runtimeRegistry.cancelCloseHandshakeTask(for: task.id)
            case .publishConnected(let protocolName):
                await runtimeRegistry.onConnected?(task, protocolName)
                await eventHub.publish(.connected(protocolName), for: task.id)
            case .publishDisconnected(let error):
                await runtimeRegistry.onDisconnected?(task, error)
                await eventHub.publishAndWaitForEnqueue(.disconnected(error), for: task.id)
            case .publishError(let error):
                await runtimeRegistry.onError?(task, error)
                await eventHub.publishAndWaitForEnqueue(.error(error), for: task.id)
            case .scheduleReconnect:
                await reconnectCoordinator.attemptReconnect(task: task) { [weak self] task in
                    await self?.startReconnecting(task)
                }
            case .finishTerminal(let generation):
                await finishTerminalLifecycle(task, generation: generation)
            case .ignoreStaleCallback:
                break
            }
        }
    }

    private func scheduleCloseHandshakeTimeout(
        for task: WebSocketTask,
        closeCode: WebSocketCloseCode
    ) async {
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else { return }
        // URLSession demands its own close-code enum at the cancel() call,
        // so convert at the Foundation boundary.
        urlTask.cancel(with: closeCode.urlSessionCloseCode, reason: nil)
        let closeHandshakeTimeout = configuration.closeHandshakeTimeout
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
    }

    private func publishPong(task: WebSocketTask, context: WebSocketPongContext) async {
        await runtimeRegistry.onPong?(task, context)
        await eventHub.publish(.pong(context), for: task.id)
    }

    nonisolated func handleConnected(taskIdentifier: Int, protocolName: String?) {
        delegateEventContinuation.yield(
            .connected(taskIdentifier: taskIdentifier, protocolName: protocolName)
        )
    }

    nonisolated func handleDisconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?) {
        delegateEventContinuation.yield(
            .disconnected(taskIdentifier: taskIdentifier, closeCode: closeCode, reason: reason)
        )
    }

    nonisolated func handleError(taskIdentifier: Int, error: Error) {
        let wsError = Self.mapWebSocketError(error)
        delegateEventContinuation.yield(
            .mappedError(taskIdentifier: taskIdentifier, error: wsError)
        )
    }

    nonisolated func handleSessionError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int? = nil) {
        delegateEventContinuation.yield(
            .sessionError(taskIdentifier: taskIdentifier, error: error, statusCode: statusCode)
        )
    }

    private func processConnected(taskIdentifier: Int, protocolName: String?) async {
        guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }
        let previousState = await task.state
        let generation = await callbackGeneration(
            for: taskIdentifier,
            fallbackTask: task
        )
        let transition = await task.applyLifecycleEvent(
            .didOpen(generation: generation, protocolName: protocolName)
        )
        let didConnect = transition.state.publicState == .connected && !transition.isIgnoredCallback

        if previousState == .reconnecting, didConnect {
            await task.incrementSuccessfulReconnectCount()
        }
        if didConnect {
            await task.resetAttemptedReconnectCount()
            await task.clearReconnectWindow()
            await task.resetPingCounter()
            await task.setAutoReconnectEnabled(true)
            await task.setError(nil)
        }
        await executeLifecycleEffects(transition.effects, for: task)
    }

    private func processDisconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?) async {
        guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }
        let previousState = await task.state
        let callbackGeneration = await callbackGeneration(
            for: taskIdentifier,
            fallbackTask: task
        )
        let isManualClose = await task.awaitingCloseHandshake
        let disposition: WebSocketCloseDisposition
        let error: WebSocketError?
        let context: WebSocketLifecycleDecisionContext

        if isManualClose {
            disposition = .manual(closeCode)
            error = await task.currentLifecycleState.manualDisconnect?.error
            context = .init()
        } else {
            disposition = WebSocketCloseDisposition.classifyPeerClose(
                closeCode,
                reason: reason
            )
            error = makeDisconnectedError(closeDisposition: disposition)
            let currentGeneration = await task.connectionGeneration
            if callbackGeneration != currentGeneration
                || previousState == .disconnecting
                || previousState == .disconnected
                || previousState == .failed
            {
                context = .init()
            } else {
                let reconnectAction = await reconnectCoordinator.reconnectAction(
                    task: task,
                    closeDisposition: disposition,
                    previousState: previousState
                )
                context = .init(
                    reconnectAction: reconnectAction,
                    attempt: await task.attemptedReconnectCount
                )
            }
        }

        let transition = await task.applyLifecycleEvent(
            .didClose(
                generation: callbackGeneration,
                closeCode: closeCode,
                disposition: disposition,
                error: error
            ),
            context: context
        )
        await executeLifecycleEffects(transition.effects, for: task)
    }

    private func processMappedError(taskIdentifier: Int, error wsError: WebSocketError) async {
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

    private func processSessionError(
        taskIdentifier: Int,
        error: SendableUnderlyingError,
        statusCode: Int?
    ) async {
        guard !Self.isCancelledTransportError(error) else { return }
        guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }

        let state = await task.state
        if state == .connecting || state == .reconnecting {
            let disposition = WebSocketCloseDisposition.classifyHandshake(
                statusCode: statusCode,
                error: error
            )
            await handleFailure(
                task: task,
                generation: await callbackGeneration(
                    for: taskIdentifier,
                    fallbackTask: task
                ),
                closeDisposition: disposition,
                previousState: state
            )
            return
        }

        let wsError: WebSocketError = Self.isTimeoutTransportError(error) ? .pingTimeout : .connectionFailed(error)
        await handleFailure(
            task: task,
            generation: await callbackGeneration(
                for: taskIdentifier,
                fallbackTask: task
            ),
            closeDisposition: .transportFailure(wsError)
        )
    }

    nonisolated static func mapWebSocketError(_ error: Error) -> WebSocketError {
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

    nonisolated static func isCancelledTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    nonisolated static func isTimeoutTransportError(_ error: SendableUnderlyingError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == URLError.timedOut.rawValue
    }

    private func handleMappedError(taskIdentifier: Int, error: WebSocketError) async {
        guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }
        await handleFailure(
            task: task,
            generation: await callbackGeneration(for: taskIdentifier, fallbackTask: task),
            closeDisposition: .transportFailure(error)
        )
    }

    private func handleFailure(
        task: WebSocketTask,
        generation: Int? = nil,
        closeDisposition: WebSocketCloseDisposition,
        previousState: WebSocketState? = nil
    ) async {
        let finalError = makeFailureError(closeDisposition: closeDisposition)
        let currentGeneration = await task.connectionGeneration
        if let generation, generation != currentGeneration {
            let transition = await task.applyLifecycleEvent(
                .failure(generation: generation, disposition: closeDisposition, error: finalError)
            )
            await executeLifecycleEffects(transition.effects, for: task)
            return
        }

        let currentState = await task.state
        if currentState == .disconnecting || currentState.isTerminal {
            let transition = await task.applyLifecycleEvent(
                .failure(generation: generation, disposition: closeDisposition, error: finalError)
            )
            await executeLifecycleEffects(transition.effects, for: task)
            return
        }

        let reconnectAction = await reconnectCoordinator.reconnectAction(
            task: task,
            closeDisposition: closeDisposition,
            previousState: previousState
        )
        let transition = await task.applyLifecycleEvent(
            .failure(generation: generation, disposition: closeDisposition, error: finalError),
            context: .init(
                reconnectAction: reconnectAction,
                attempt: await task.attemptedReconnectCount
            )
        )
        await executeLifecycleEffects(transition.effects, for: task)
    }

    private func startReconnecting(_ task: WebSocketTask) async {
        let transition = await task.applyLifecycleEvent(.reconnectTimerFired)
        await executeLifecycleEffects(transition.effects, for: task)
    }

    private func callbackGeneration(
        for taskIdentifier: Int,
        fallbackTask task: WebSocketTask
    ) async -> Int {
        if let generation = await runtimeRegistry.connectionGeneration(for: taskIdentifier) {
            return generation
        }
        return await task.connectionGeneration
    }

    private func finishTerminalLifecycle(_ task: WebSocketTask, generation: Int) async {
        await finishTerminalTaskIfCurrent(task, generation: generation)
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
        if let urlTask = await runtimeRegistry.urlTask(for: taskID) {
            urlTask.cancel()
        }
        let finalError = makeDisconnectedError(
            closeDisposition: .handshakeTimeout(closeCode)
        )
        let transition = await task.applyLifecycleEvent(
            .closeTimeout(closeCode: closeCode, error: finalError)
        )
        await executeLifecycleEffects(transition.effects, for: task)
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

    /// Completes AppDelegate-style background URLSession callbacks immediately.
    ///
    /// `WebSocketManager` does not own background URLSession processing, so the
    /// identifier is intentionally ignored. The method is `nonisolated` so it
    /// can be called without `await`, mirroring
    /// `handleEventsForBackgroundURLSession` callback semantics.
    ///
    /// - Parameters:
    ///   - identifier: Accepted for API compatibility with background session
    ///     completion callbacks.
    ///   - completion: Called immediately to satisfy the callback contract.
    nonisolated public func handleBackgroundSessionCompletion(
        _ identifier: String,
        completion: @escaping @Sendable () -> Void
    ) {
        webSocketManagerLogger.debug(
            "Ignoring background completion identifier for WebSocket runtime: \(identifier, privacy: .public)")
        completion()
    }

    nonisolated private var isShutdown: Bool {
        shutdownLock.withLock { $0 }
    }

    nonisolated private func markShutdownIfNeeded() -> Bool {
        shutdownLock.withLock { state in
            guard !state else { return false }
            state = true
            return true
        }
    }

    private static func managerShutdownError() -> WebSocketError {
        .connectionFailed(
            SendableUnderlyingError(
                domain: "InnoNetworkWebSocket.Manager",
                code: 1,
                message: "WebSocketManager has been shut down."
            )
        )
    }
}
