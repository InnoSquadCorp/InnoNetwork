import Foundation
import InnoNetwork
import OSLog
import os

let webSocketManagerLogger = Logger(
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
    // Visibility note: stored properties and the `DelegateEvent` enum are
    // module-internal (no `private`) so the extension files
    // (`WebSocketManager+DelegateBridge.swift`,
    // `+LifecycleEffects.swift`, `+FailureHandling.swift`,
    // `+ErrorMapping.swift`) can reference them. The actor itself stays
    // `public`, so the package boundary is unchanged.
    let configuration: WebSocketConfiguration
    let session: any WebSocketURLSession
    let delegate: WebSocketSessionDelegate

    package let runtimeRegistry = WebSocketRuntimeRegistry()
    let eventHub: TaskEventHub<WebSocketEvent>
    /// `OSAllocatedUnfairLock` is preserved here even after the actor
    /// conversion: the shutdown flag has to stay readable from the
    /// nonisolated ``deinit`` and from synchronous URLSession delegate
    /// callbacks, neither of which can hop onto the actor executor. The
    /// lock is internally `Sendable`, so a `nonisolated let` field is
    /// safe.
    nonisolated let shutdownLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    let invalidationBarrier: WebSocketInvalidationBarrier

    /// One-shot serialized event channel for URLSession delegate callbacks.
    /// `WebSocketSessionDelegate` invokes the four `handle*` entry points
    /// synchronously from arbitrary delegate-queue threads — without this
    /// channel each call would spawn its own `Task`, allowing
    /// `didOpen → didReceive → didClose` to interleave on the actor
    /// executor and (rarely) reorder the lifecycle observed by a single
    /// task. The single consumer Task drains in arrival order so each
    /// task identifier observes a strict FIFO of its own callbacks.
    nonisolated let delegateEventContinuation: AsyncStream<DelegateEvent>.Continuation

    enum DelegateEvent: Sendable {
        case connected(taskIdentifier: Int, protocolName: String?)
        case disconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?)
        case mappedError(taskIdentifier: Int, error: WebSocketError)
        case sessionError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int?)
    }

    var receiveLoop: WebSocketReceiveLoop {
        WebSocketReceiveLoop(
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    var connectionCoordinator: WebSocketConnectionCoordinator {
        WebSocketConnectionCoordinator(
            configuration: configuration,
            session: session,
            runtimeRegistry: runtimeRegistry,
            receiveLoop: receiveLoop
        )
    }

    var reconnectCoordinator: WebSocketReconnectCoordinator {
        WebSocketReconnectCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    var heartbeatCoordinator: WebSocketHeartbeatCoordinator {
        WebSocketHeartbeatCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    /// Creates a WebSocket manager backed by a URLSession WebSocket runtime.
    ///
    /// The initializer builds a `WebSocketSessionDelegate` with
    /// `WebSocketSessionDelegateCallbacks` and `BackgroundCompletionStore`,
    /// then creates a `URLSession` from
    /// ``WebSocketConfiguration/makeURLSessionConfiguration()``. The manager
    /// owns that delegate and uses its background-completion store to satisfy
    /// URLSession-style completion callbacks.
    ///
    /// - Parameter configuration: WebSocket runtime configuration. Defaults to
    ///   ``WebSocketConfiguration/default``.
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

    nonisolated var isShutdown: Bool {
        shutdownLock.withLock { $0 }
    }

    nonisolated func markShutdownIfNeeded() -> Bool {
        shutdownLock.withLock { state in
            guard !state else { return false }
            state = true
            return true
        }
    }
}
