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
/// let manager = WebSocketManager(configuration: .safeDefaults())
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
    let clock: any InnoNetworkClock

    package let runtimeRegistry = WebSocketRuntimeRegistry()
    let eventHub: TaskEventHub<WebSocketEvent>
    /// `OSAllocatedUnfairLock` is preserved here even after the actor
    /// conversion: the shutdown flag has to stay readable from the
    /// nonisolated ``deinit`` and from synchronous URLSession delegate
    /// callbacks, neither of which can hop onto the actor executor. Shutdown
    /// uses it as the admission fence for the single delegate consumer, then
    /// awaits that consumer before beginning terminal task cleanup. The lock
    /// is internally `Sendable`, so a `nonisolated let` field is safe.
    nonisolated let shutdownLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    let invalidationBarrier: WebSocketInvalidationBarrier
    /// Separate from URLSession invalidation: concurrent external callers must
    /// not return until delegate drain, task cleanup, and callback clearing are
    /// all complete.
    let shutdownCompletionBarrier: WebSocketInvalidationBarrier

    /// One-shot serialized event channel for URLSession delegate callbacks.
    /// `WebSocketSessionDelegate` invokes the four `handle*` entry points
    /// synchronously from arbitrary delegate-queue threads — without this
    /// channel each call would spawn its own `Task`, allowing
    /// `didOpen → didReceive → didClose` to interleave on the actor
    /// executor and (rarely) reorder the lifecycle observed by a single
    /// task. The single consumer Task drains in arrival order so each
    /// task identifier observes a strict FIFO of its own callbacks.
    nonisolated let delegateEventContinuation: AsyncStream<DelegateEvent>.Continuation

    /// Handle for the consumer Task that drains `delegateEventContinuation`.
    /// `shutdown()` closes the channel and awaits this task so the delegate
    /// consumer fully unwinds before the manager returns control — mirroring the
    /// symmetric task lifetime used by `DownloadManager`. Without this
    /// handle the consumer was orphaned: `delegateEventContinuation.finish()`
    /// would let the for-await loop fall through, but `shutdown()` could not
    /// await the loop's completion before its terminal sweep. An accepted
    /// event could then resume after cleanup and reinstall runtime state.
    ///
    /// Stored behind a `nonisolated` lock so the init body (itself
    /// `nonisolated`) can assign the task while the actor's isolated
    /// `shutdown()` reads and clears it.
    nonisolated let delegateConsumerTaskLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Counts public API work and internal timer transactions that passed the
    /// shutdown admission fence. Teardown drains this set before taking its
    /// terminal registry snapshot.
    var activeShutdownTrackedOperationCount = 0
    var shutdownTrackedOperationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Consumer registration is a cross-actor transaction: admission is
    /// decided on the manager, while the listener or stream is installed on
    /// `TaskEventHub`. Terminal cleanup closes this per-task fence and drains
    /// admitted registrations before closing the hub partition.
    var eventConsumerAdmissionClosedTaskIDs: Set<String> = []
    var activeEventConsumerRegistrationCounts: [String: Int] = [:]
    var eventConsumerRegistrationDrainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Serializes explicit retry preparation with terminal partition cleanup.
    /// The source-task gate is held only through retirement and replacement
    /// registration, never through a transport start that can itself produce
    /// a terminal lifecycle effect.
    var taskLifecycleGateOwners: Set<String> = []
    var taskLifecycleGateWaiters: [String: [TaskLifecycleGateWaiter]] = [:]

    struct TaskLifecycleGateWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    enum DelegateEvent: Sendable {
        case connected(taskIdentifier: Int, protocolName: String?)
        case disconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?)
        case mappedError(taskIdentifier: Int, error: WebSocketError)
        case redirectRejected(taskIdentifier: Int, error: WebSocketError)
        case sessionError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int?)
        case pingTimeout(taskIdentifier: Int)
    }

    enum RetryPreparationResult {
        case ready(WebSocketTask)
        case ineligible
        case managerShutdown(WebSocketTask)
    }

    var receiveLoop: WebSocketReceiveLoop {
        WebSocketReceiveLoop(
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub
        )
    }

    var connectionCoordinator: WebSocketConnectionCoordinator {
        let shutdownLock = self.shutdownLock
        return WebSocketConnectionCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            isTransportAdmissionOpen: {
                shutdownLock.withLock { !$0 }
            }
        )
    }

    var reconnectCoordinator: WebSocketReconnectCoordinator {
        let clock = self.clock
        return WebSocketReconnectCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            clock: clock,
            dateProvider: { clock.now() },
            eventHub: eventHub
        )
    }

    var heartbeatCoordinator: WebSocketHeartbeatCoordinator {
        WebSocketHeartbeatCoordinator(
            configuration: configuration,
            runtimeRegistry: runtimeRegistry,
            eventHub: eventHub,
            clock: clock
        )
    }

    /// Creates a WebSocket manager backed by a URLSession WebSocket runtime.
    ///
    /// The initializer builds a `WebSocketSessionDelegate` with
    /// `WebSocketSessionDelegateCallbacks`, then creates a foreground
    /// `URLSession` from
    /// ``WebSocketConfiguration/makeURLSessionConfiguration()``.
    ///
    /// - Parameter configuration: WebSocket runtime configuration. Defaults to
    ///   ``WebSocketConfiguration/safeDefaults()``.
    public init(configuration: WebSocketConfiguration = .safeDefaults()) {
        let callbacks = WebSocketSessionDelegateCallbacks()
        let delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
            allowsInsecureWebSocket: configuration.allowsInsecureWebSocket
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
        callbacks: WebSocketSessionDelegateCallbacks,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.configuration = configuration
        self.delegate = delegate
        self.clock = clock
        self.eventHub = TaskEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .webSocketTask
        )
        self.session = urlSession
        let invalidationBarrier = WebSocketInvalidationBarrier()
        self.invalidationBarrier = invalidationBarrier
        self.shutdownCompletionBarrier = WebSocketInvalidationBarrier()

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
        // per-callback `Task` spawning could not guarantee. The Task
        // handle is stored so `shutdown()` can close admission and await it
        // before its terminal sweep, matching the symmetric lifetime used by
        // `DownloadManager` and guaranteeing an accepted delegate event is
        // never partially interleaved with cleanup.
        let consumerTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.processDelegateEvent(event)
            }
        }
        delegateConsumerTaskLock.withLock { $0 = consumerTask }

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
            },
            onRedirectRejected: { [weak self] taskIdentifier, error in
                self?.handleRedirectRejected(taskIdentifier: taskIdentifier, error: error)
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
        guard !isShutdown else { return }
        await runtimeRegistry.setOnConnected(callback)
    }

    /// Sets a callback that runs when a socket disconnects.
    ///
    /// - Parameter callback: Optional async handler receiving the disconnected task and optional
    ///   disconnect error detail.
    /// - Note: The handler is invoked after task state is transitioned to `.disconnected`.
    public func setOnDisconnectedHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) async
    {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnDisconnected(callback)
    }

    /// Sets a callback that runs when binary message data is received.
    ///
    /// - Parameter callback: Optional async handler receiving the source task and message payload.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    public func setOnMessageHandler(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnMessage(callback)
    }

    /// Sets a callback that runs when a text message is received.
    ///
    /// - Parameter callback: Optional async handler receiving the source task and UTF-8 string.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    public func setOnStringHandler(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnString(callback)
    }

    /// Sets a callback that runs when an operational WebSocket error occurs.
    ///
    /// - Parameter callback: Optional async handler receiving the task and mapped `WebSocketError`.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    public func setOnErrorHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnError(callback)
    }

    /// Sets a callback that runs when a ping's paired pong is observed.
    ///
    /// - Parameter callback: Optional async handler receiving the task and a
    ///   ``WebSocketPongContext`` carrying the ping attempt number and
    ///   library-computed round-trip duration.
    /// - Note: The handler is invoked from an internal async context, not the main actor.
    /// - Note: On success, publication of the paired `.pong` event is attempted
    ///   before the snapshotted handler runs. Normal event overflow policy still
    ///   applies, and listener delivery remains asynchronous, so consumers must
    ///   not depend on which callback surface executes first.
    public func setOnPongHandler(_ callback: (@Sendable (WebSocketTask, WebSocketPongContext) async -> Void)?) async {
        guard !isShutdown else { return }
        await runtimeRegistry.setOnPong(callback)
    }

    @discardableResult
    public func connect(url: URL, subprotocols: [String]? = nil) async -> WebSocketTask {
        let task = WebSocketTask(url: url, subprotocols: subprotocols)
        // Ownership is part of task identity, including the terminal task
        // returned when this manager has already shut down. Assign it before
        // admission so a different manager cannot adopt that failed handle.
        _ = await task.assignOwnerIfUnowned(runtimeRegistry.callbackContextID)
        do {
            try NetworkURLAdmission.validate(
                url,
                policy: .webSocket(allowsInsecure: configuration.allowsInsecureWebSocket)
            )
        } catch {
            let admissionError = WebSocketError.invalidURL("Rejected by URL admission policy")
            _ = await task.applyLifecycleEvent(
                .failure(
                    generation: nil,
                    disposition: .transportFailure(admissionError),
                    error: admissionError
                ),
                context: .init(reconnectAction: .terminal)
            )
            return task
        }
        guard beginShutdownTrackedOperation() else {
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
        defer { finishShutdownTrackedOperation() }
        // This operation was admitted before shutdown, so the shutdown worker
        // drains it before taking the registry snapshot. The registry's own
        // closed-state guard still rejects internal additions after the sweep
        // begins.
        guard await runtimeRegistry.add(task) else {
            await finishTaskBecauseManagerIsShutdown(task)
            return task
        }
        await startConnection(task)
        return task
    }

    public func disconnect(_ task: WebSocketTask, closeCode: WebSocketCloseCode = .normalClosure) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }

        let state = await task.state
        switch state {
        case .connected, .connecting, .reconnecting:
            break
        case .idle, .disconnecting, .disconnected, .failed:
            return
        }

        let disconnectError: WebSocketError? = makeManualDisconnectError(closeCode: closeCode)
        await acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        let transition = await task.applyLifecycleEvent(
            .manualDisconnect(closeCode: closeCode, error: disconnectError)
        )
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)

        if await runtimeRegistry.urlTask(for: task.id) == nil,
            await task.awaitingCloseHandshake
        {
            await acquireTaskLifecycleGateUnconditionally(taskID: task.id)
            let closeTransition = await task.applyLifecycleEvent(
                .didClose(
                    generation: await task.connectionGeneration,
                    closeCode: closeCode,
                    disposition: .manual(closeCode),
                    error: disconnectError
                )
            )
            await executeLifecycleEffectsAfterLockedApply(closeTransition, for: task)
        }
    }

    public func disconnectAll(closeCode: WebSocketCloseCode = .normalClosure) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }

        for task in await runtimeRegistry.allTasks() {
            await disconnect(task, closeCode: closeCode)
        }
    }

    /// Tears down the manager, cancels active sockets, finishes event streams,
    /// and invalidates the underlying URLSession.
    ///
    /// Every registered, nonterminal task transitions to `.failed` and emits
    /// exactly one shutdown `.error(_:)` before its event stream finishes.
    /// The same error is delivered to ``setOnErrorHandler(_:)``; shutdown does
    /// not synthesize a `.disconnected` event because no peer-close handshake
    /// occurred. Callbacks installed through the `setOn...Handler` methods are
    /// drained and cleared after this terminal sweep, so none remain active
    /// when an external shutdown call returns. Task event listeners and
    /// `AsyncStream` consumers keep their configured delivery semantics and
    /// can consume terminal events that were already enqueued before finish.
    /// Handler registrations attempted after shutdown admission are ignored.
    ///
    /// After `shutdown()` returns, the manager is terminal. Create a fresh
    /// instance for new socket work; diagnostic getters can still return their
    /// last-known values while terminal cleanup drains. Calling `shutdown()`
    /// multiple times is safe.
    ///
    /// A call made from one of this manager's async handlers initiates teardown
    /// and returns to let that handler unwind instead of awaiting its own
    /// worker. A subsequent call from outside a handler waits for the complete
    /// shutdown boundary.
    public func shutdown() async {
        let callbackToken = WebSocketUserCallbackContext.token
        let isReentrantCallback =
            callbackToken?.containsActiveCallback(
                for: runtimeRegistry.callbackContextID
            ) == true
        if markShutdownIfNeeded() {
            delegateEventContinuation.finish()

            // Invalidate transport promptly so Foundation can release any
            // pending receives while the accepted delegate event finishes.
            // Task cleanup is deliberately deferred until the consumer drain.
            session.invalidateAndCancel()

            // Preserve the complete callback ancestry. Reciprocal shutdowns
            // across managers can otherwise lose the outer manager's active
            // token and misclassify a reentrant call as external. Tokens turn
            // inactive when their handlers return, so retaining the chain does
            // not make an outliving child permanently reentrant.
            Task { [self, callbackToken] in
                await WebSocketRuntimeWorkerContext.$selfDrainDisabled.withValue(true) {
                    await WebSocketRuntimeWorkerContext.$workerID.withValue(nil) {
                        await WebSocketUserCallbackContext.$token.withValue(callbackToken) {
                            await self.performShutdown()
                        }
                    }
                }
            }
        }

        // A handler cannot await the worker that is currently invoking it.
        // The dedicated shutdown task above owns cleanup; external callers
        // still observe the strong, fully-drained completion boundary.
        guard !isReentrantCallback else { return }
        await shutdownCompletionBarrier.wait()
    }

    private func performShutdown() async {
        // Buffered events fail processDelegateEvent's admission guard because
        // the shutdown flag is already closed. An event that passed the guard
        // before shutdown is allowed to finish as one logical transaction.
        let consumerTask = delegateConsumerTaskLock.withLock { task -> Task<Void, Never>? in
            let snapshot = task
            task = nil
            return snapshot
        }
        if let consumerTask {
            await consumerTask.value
        }
        await waitForShutdownTrackedOperationsToDrain()

        // Atomically flip the registry into a "no new tasks" state and capture
        // the live snapshot in a single actor hop. Any concurrent
        // `connect()`/`retry()` past this point will be refused at `add(_:)`
        // and routed through `finishTaskBecauseManagerIsShutdown`.
        for task in await runtimeRegistry.markShutdownStartedAndSnapshot() {
            await finishTaskBecauseManagerIsShutdown(task)
        }

        // Keep manager-level callbacks alive through the terminal sweep so
        // callback-only consumers observe the same shutdown error as stream
        // consumers. The delegate consumer has fully drained, so clearing the
        // callbacks establishes a strict no-callback boundary afterwards.
        await runtimeRegistry.clearCallbacks()
        await runtimeRegistry.waitForUserCallbacksToDrain()

        await invalidationBarrier.wait()
        await shutdownCompletionBarrier.complete()
    }

    /// Starts an explicit retry as a fresh logical WebSocket task.
    ///
    /// The terminal `task` keeps its terminal lifecycle snapshot and identity;
    /// its existing listeners and streams stay bound to the retired task ID.
    /// Consume the returned result's pre-registered event stream. Automatic
    /// reconnect is unchanged and continues to reuse its task handle across
    /// transport generations.
    ///
    /// - Returns: A fresh task and its pre-registered bounded event stream after
    ///   connection setup has completed. If shutdown wins after retry admission,
    ///   the returned replacement is already terminal with the manager-shutdown
    ///   error and the stream contains that terminal outcome. Returns
    ///   `nil` when the source task is nonterminal, already claimed by another
    ///   retry, owned by another manager, or shutdown admission is closed.
    public func retry(_ task: WebSocketTask) async -> WebSocketRetryResult? {
        guard beginShutdownTrackedOperation() else { return nil }
        defer { finishShutdownTrackedOperation() }

        switch await prepareTaskForRetry(task) {
        case .ready(let replacement):
            // Register the retry-owned stream before the transport can resume.
            // A synchronous delegate callback from resume() can therefore be
            // published immediately without racing consumer registration.
            let events = await eventHub.stream(for: replacement.id)
            await startConnection(replacement)
            // Shutdown flips its admission flag before draining tracked
            // operations. A retry admitted just before that flip can finish
            // replacement registration while startConnection correctly
            // refuses to create a transport. Complete that replacement here
            // so retry never returns a stranded nonterminal handle.
            if isShutdown {
                await finishTaskBecauseManagerIsShutdown(replacement)
            }
            return WebSocketRetryResult(task: replacement, events: events)
        case .ineligible:
            return nil
        case .managerShutdown(let replacement):
            // The shutdown-race path still returns an observable terminal
            // replacement. Register its stream before publishing and closing
            // the manager-shutdown outcome.
            let events = await eventHub.stream(for: replacement.id)
            await finishTaskBecauseManagerIsShutdown(replacement)
            return WebSocketRetryResult(task: replacement, events: events)
        }
    }

    private func prepareTaskForRetry(_ task: WebSocketTask) async -> RetryPreparationResult {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return .ineligible }
        defer { releaseTaskLifecycleGate(taskID: task.id) }

        guard
            await task.claimExplicitRetry(
                requestingManagerID: runtimeRegistry.callbackContextID
            )
        else { return .ineligible }
        await closeEventConsumerAdmissionAndWait(taskID: task.id)
        defer { reopenEventConsumerAdmission(taskID: task.id) }
        // Retire the source task completely before registering its replacement.
        // The replacement has a fresh ID, so late events from this partition
        // can never target its runtime or consumer set.
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finishAndWaitForClosure(taskID: task.id)
        await runtimeRegistry.remove(task)

        let replacement = WebSocketTask(
            url: task.url,
            subprotocols: task.subprotocols
        )
        _ = await replacement.assignOwnerIfUnowned(runtimeRegistry.callbackContextID)
        // An admitted retry drains before shutdown snapshots the registry; the
        // registry guard remains the final backstop once that snapshot begins.
        guard await runtimeRegistry.add(replacement) else {
            return .managerShutdown(replacement)
        }
        return .ready(replacement)
    }

    public func send(_ task: WebSocketTask, message: Data) async throws {
        guard beginShutdownTrackedOperation() else {
            throw Self.managerShutdownError()
        }
        defer { finishShutdownTrackedOperation() }
        try await sendGuarded(task: task) { urlTask in
            try await urlTask.send(.data(message))
        }
    }

    public func send(_ task: WebSocketTask, string: String) async throws {
        guard beginShutdownTrackedOperation() else {
            throw Self.managerShutdownError()
        }
        defer { finishShutdownTrackedOperation() }
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
        guard let (generation, urlTask) = try await prepareSend(task: task, limit: limit) else { return }

        do {
            try await body(urlTask)
            await task.releaseSendSlot(generation: generation)
        } catch {
            await task.releaseSendSlot(generation: generation)
            throw error
        }
    }

    /// Reserves a send and publishes overflow telemetry while holding the
    /// task lifecycle gate. The transport send itself remains outside the gate
    /// so terminal cleanup can cancel an in-flight network operation.
    private func prepareSend(
        task: WebSocketTask,
        limit: Int
    ) async throws -> (generation: Int, urlTask: any WebSocketURLTask)? {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { throw CancellationError() }
        defer { releaseTaskLifecycleGate(taskID: task.id) }

        let generation = await task.connectionGeneration
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id),
            await isCurrentConnectedRuntime(task, generation: generation, urlTask: urlTask),
            let reserved = await task.tryReserveConnectedSendSlot(limit: limit)
        else {
            throw WebSocketError.disconnected(nil)
        }
        guard reserved else {
            switch configuration.sendQueueOverflowPolicy {
            case .fail:
                throw WebSocketError.sendQueueOverflow(limit: limit)
            case .dropNewest:
                await eventHub.publish(.sendDropped(limit: limit), for: task.id)
                return nil
            }
        }
        return (generation, urlTask)
    }

    public func ping(_ task: WebSocketTask) async throws {
        guard beginShutdownTrackedOperation() else {
            throw Self.managerShutdownError()
        }
        defer { finishShutdownTrackedOperation() }

        let (generation, urlTask, context) = try await preparePing(task)
        do {
            try await heartbeatCoordinator.sendPing(urlTask, timeout: configuration.pongTimeout)
            let pongContext = WebSocketPongContext(
                attemptNumber: context.attemptNumber,
                roundTrip: ContinuousClock.now - context.dispatchedAt
            )
            await publishPongIfCurrent(
                task: task,
                generation: generation,
                urlTask: urlTask,
                context: pongContext
            )
        } catch {
            let wsError = Self.mapWebSocketError(error)
            await publishPingErrorIfCurrent(
                task: task,
                generation: generation,
                urlTask: urlTask,
                error: wsError
            )
            throw wsError
        }
    }

    private func preparePing(
        _ task: WebSocketTask
    ) async throws -> (Int, any WebSocketURLTask, WebSocketPingContext) {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { throw CancellationError() }
        defer { releaseTaskLifecycleGate(taskID: task.id) }

        let generation = await task.connectionGeneration
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id),
            await isCurrentConnectedRuntime(task, generation: generation, urlTask: urlTask),
            let attempt = await task.nextConnectedPingAttempt()
        else {
            throw WebSocketError.disconnected(nil)
        }
        let context = WebSocketPingContext(attemptNumber: attempt, dispatchedAt: .now)
        await eventHub.publish(.ping(context), for: task.id)
        return (generation, urlTask, context)
    }

    private func publishPongIfCurrent(
        task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask,
        context: WebSocketPongContext
    ) async {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        guard await isCurrentConnectedRuntime(task, generation: generation, urlTask: urlTask) else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }
        let prepared = await runtimeRegistry.preparePongCallback(
            task,
            context: context
        )
        await eventHub.publish(.pong(context), for: task.id)
        releaseTaskLifecycleGate(taskID: task.id)

        // Snapshot the handler and attempt paired-event publication while the
        // runtime is still current, then let user code run outside the
        // lifecycle gate. A callback that disconnects cannot race ahead of the
        // publication attempt, and can still send, ping, or close.
        await runtimeRegistry.invokePreparedUserCallback(prepared)
    }

    /// Publishes a scheduled heartbeat ping only while its worker still owns
    /// the connected runtime. Holding the lifecycle gate makes the event occur
    /// entirely before a reconnect/terminal transition, or suppresses it when
    /// that transition won first.
    func admitHeartbeatPingIfCurrent(
        task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask
    ) async -> WebSocketPingContext? {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return nil }
        defer { releaseTaskLifecycleGate(taskID: task.id) }
        guard
            await isCurrentConnectedRuntime(
                task,
                generation: generation,
                urlTask: urlTask
            ),
            await runtimeRegistry.isCurrentHeartbeatWorker(for: task.id),
            let attempt = await task.nextConnectedPingAttempt()
        else { return nil }

        let context = WebSocketPingContext(
            attemptNumber: attempt,
            dispatchedAt: .now
        )
        await eventHub.publish(.ping(context), for: task.id)
        return context
    }

    /// Applies the same linearization boundary to a recoverable missed-pong
    /// notification. Cancellation-driven teardown is handled by the heartbeat
    /// loop itself; this check also suppresses transport errors that race a
    /// reconnect or terminal transition before cancellation becomes visible.
    func publishHeartbeatErrorIfCurrent(
        task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask,
        error: WebSocketError
    ) async -> Bool {
        await publishHeartbeatEventIfCurrent(
            .error(error),
            task: task,
            generation: generation,
            urlTask: urlTask
        )
    }

    private func publishHeartbeatEventIfCurrent(
        _ event: WebSocketEvent,
        task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask
    ) async -> Bool {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return false }
        defer { releaseTaskLifecycleGate(taskID: task.id) }
        guard
            await isCurrentConnectedRuntime(
                task,
                generation: generation,
                urlTask: urlTask
            ),
            await runtimeRegistry.isCurrentHeartbeatWorker(for: task.id)
        else { return false }

        await eventHub.publish(event, for: task.id)
        return true
    }

    /// Commits a heartbeat pong to the old event partition while holding the
    /// lifecycle gate, but invokes user code only after releasing it. Callback
    /// admission is atomic with heartbeat-worker identity validation in the
    /// registry: terminal cleanup either suppresses a detached worker or sees
    /// the admitted callback and avoids awaiting its own retry path.
    func publishHeartbeatPongIfCurrent(
        task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask,
        context: WebSocketPongContext
    ) async {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        guard await isCurrentConnectedRuntime(task, generation: generation, urlTask: urlTask) else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }
        let prepared = await runtimeRegistry.preparePongCallbackFromCurrentHeartbeatWorker(
            task,
            context: context
        )
        guard prepared.isCurrentWorker else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }
        await eventHub.publish(.pong(context), for: task.id)
        releaseTaskLifecycleGate(taskID: task.id)
        await runtimeRegistry.invokePreparedUserCallback(prepared.callback)
    }

    /// Linearizes one receive-loop occurrence across both observation
    /// surfaces. Runtime detachment either wins before callback/event
    /// admission, or waits until the paired event has entered the bounded
    /// pipeline and the matching handler has been snapshotted.
    func publishReceiveEventIfCurrent(
        _ event: WebSocketEvent,
        task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask
    ) async {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        guard
            await isCurrentConnectedRuntime(
                task,
                generation: generation,
                urlTask: urlTask
            )
        else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }

        let prepared: WebSocketPreparedWorkerCallback
        switch event {
        case .message(let data):
            prepared = await runtimeRegistry.prepareMessageEventFromCurrentWorker(
                task,
                data: data
            )
        case .string(let string):
            prepared = await runtimeRegistry.prepareStringEventFromCurrentWorker(
                task,
                string: string
            )
        case .connected, .disconnected, .ping, .pong, .error, .sendDropped:
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }

        guard prepared.isCurrentWorker else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }
        await eventHub.publish(event, for: task.id)
        releaseTaskLifecycleGate(taskID: task.id)
        await runtimeRegistry.invokePreparedUserCallback(prepared.callback)
    }

    private func publishPingErrorIfCurrent(
        task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask,
        error: WebSocketError
    ) async {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        defer { releaseTaskLifecycleGate(taskID: task.id) }
        guard await isCurrentConnectedRuntime(task, generation: generation, urlTask: urlTask) else { return }
        await eventHub.publish(.error(error), for: task.id)
    }

    private func isCurrentConnectedRuntime(
        _ task: WebSocketTask,
        generation: Int,
        urlTask: any WebSocketURLTask
    ) async -> Bool {
        guard !isShutdown else { return false }
        guard let registeredTask = await runtimeRegistry.task(withId: task.id), registeredTask === task else {
            return false
        }
        guard let currentURLTask = await runtimeRegistry.urlTask(for: task.id), currentURLTask === urlTask else {
            return false
        }
        return await task.isConnected(generation: generation)
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

    /// Adds a module-owned event listener for a socket task.
    ///
    /// - Parameters:
    ///   - task: Target task to observe.
    ///   - listener: Listener invoked for each emitted `WebSocketEvent`.
    /// - Returns: A subscription token used to remove the listener later.
    /// - Note: Listener callbacks are invoked from an internal async context, not the main actor.
    /// - Note: Registration after shutdown begins returns an inert subscription.
    func addEventListener(
        for task: WebSocketTask,
        listener: @escaping @Sendable (WebSocketEvent) async -> Void
    ) async -> WebSocketEventSubscription {
        guard beginShutdownTrackedOperation() else {
            return WebSocketEventSubscription(taskId: task.id, listenerID: UUID())
        }
        defer { finishShutdownTrackedOperation() }
        guard beginEventConsumerRegistration(taskID: task.id) else {
            return WebSocketEventSubscription(taskId: task.id, listenerID: UUID())
        }
        defer { finishEventConsumerRegistration(taskID: task.id) }
        guard let registeredTask = await runtimeRegistry.task(withId: task.id),
            registeredTask === task,
            !(await task.state.isTerminal)
        else {
            return WebSocketEventSubscription(taskId: task.id, listenerID: UUID())
        }
        let listenerID = await eventHub.addListener(taskID: task.id, listener: listener)
        return WebSocketEventSubscription(taskId: task.id, listenerID: listenerID)
    }

    /// Removes a module-owned event listener using its subscription token.
    ///
    /// - Parameter subscription: Token returned by `addEventListener(for:listener:)`.
    func removeEventListener(_ subscription: WebSocketEventSubscription) async {
        await eventHub.removeListener(taskID: subscription.taskId, listenerID: subscription.listenerID)
    }

    /// Creates an `AsyncStream` of WebSocket events for a task.
    ///
    /// - Parameter task: Target task to observe.
    /// - Returns: Event stream that remains active until iteration stops or terminal cleanup occurs.
    ///   A request made after shutdown begins returns an already-finished stream.
    /// - Note: Listener registration completes before this method returns, so no initial events are lost.
    public func events(for task: WebSocketTask) async -> AsyncStream<WebSocketEvent> {
        guard beginShutdownTrackedOperation() else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        defer { finishShutdownTrackedOperation() }
        guard beginEventConsumerRegistration(taskID: task.id) else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        defer { finishEventConsumerRegistration(taskID: task.id) }
        guard let registeredTask = await runtimeRegistry.task(withId: task.id),
            registeredTask === task,
            !(await task.state.isTerminal)
        else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return await eventHub.stream(for: task.id)
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

    func beginShutdownTrackedOperation() -> Bool {
        guard !isShutdown else { return false }
        activeShutdownTrackedOperationCount += 1
        return true
    }

    func finishShutdownTrackedOperation() {
        activeShutdownTrackedOperationCount -= 1
        guard activeShutdownTrackedOperationCount == 0 else { return }
        let waiters = shutdownTrackedOperationDrainWaiters
        shutdownTrackedOperationDrainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForShutdownTrackedOperationsToDrain() async {
        guard activeShutdownTrackedOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            shutdownTrackedOperationDrainWaiters.append(continuation)
        }
    }

    func beginEventConsumerRegistration(taskID: String) -> Bool {
        guard !eventConsumerAdmissionClosedTaskIDs.contains(taskID) else { return false }
        activeEventConsumerRegistrationCounts[taskID, default: 0] += 1
        return true
    }

    func finishEventConsumerRegistration(taskID: String) {
        guard let activeCount = activeEventConsumerRegistrationCounts[taskID], activeCount > 0 else { return }
        if activeCount > 1 {
            activeEventConsumerRegistrationCounts[taskID] = activeCount - 1
            return
        }

        activeEventConsumerRegistrationCounts.removeValue(forKey: taskID)
        let waiters = eventConsumerRegistrationDrainWaiters.removeValue(forKey: taskID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func closeEventConsumerAdmissionAndWait(taskID: String) async {
        eventConsumerAdmissionClosedTaskIDs.insert(taskID)
        guard activeEventConsumerRegistrationCounts[taskID, default: 0] > 0 else { return }
        await withCheckedContinuation { continuation in
            eventConsumerRegistrationDrainWaiters[taskID, default: []].append(continuation)
        }
    }

    func reopenEventConsumerAdmission(taskID: String) {
        eventConsumerAdmissionClosedTaskIDs.remove(taskID)
    }

    func isEventConsumerAdmissionClosed(taskID: String) -> Bool {
        eventConsumerAdmissionClosedTaskIDs.contains(taskID)
    }

    /// Acquires the per-task lifecycle gate while remaining responsive to
    /// cancellation. Runtime workers are cancelled and drained by terminal
    /// cleanup; a cancelled worker must be able to leave this queue instead
    /// of waiting for the cleanup-owned gate and forming a circular wait.
    func acquireTaskLifecycleGate(taskID: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        if taskLifecycleGateOwners.insert(taskID).inserted {
            guard !Task.isCancelled else {
                taskLifecycleGateOwners.remove(taskID)
                return false
            }
            return true
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                taskLifecycleGateWaiters[taskID, default: []].append(
                    TaskLifecycleGateWaiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelTaskLifecycleGateWaiter(taskID: taskID, waiterID: waiterID) }
        }

        guard acquired else { return false }
        guard !Task.isCancelled else {
            releaseTaskLifecycleGate(taskID: taskID)
            return false
        }
        return true
    }

    /// Terminal cleanup is a fail-closed transaction: once the lifecycle
    /// reducer emits terminal effects it must acquire the gate even when the
    /// caller that delivered the terminal signal has itself been cancelled.
    func acquireTaskLifecycleGateUnconditionally(taskID: String) async {
        guard !taskLifecycleGateOwners.insert(taskID).inserted else { return }
        _ = await withCheckedContinuation { continuation in
            taskLifecycleGateWaiters[taskID, default: []].append(
                TaskLifecycleGateWaiter(id: UUID(), continuation: continuation)
            )
        }
    }

    func cancelTaskLifecycleGateWaiter(taskID: String, waiterID: UUID) {
        guard var waiters = taskLifecycleGateWaiters[taskID],
            let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }

        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            taskLifecycleGateWaiters.removeValue(forKey: taskID)
        } else {
            taskLifecycleGateWaiters[taskID] = waiters
        }
        waiter.continuation.resume(returning: false)
    }

    func taskLifecycleGateWaiterCount(taskID: String) -> Int {
        taskLifecycleGateWaiters[taskID]?.count ?? 0
    }

    func releaseTaskLifecycleGate(taskID: String) {
        guard var waiters = taskLifecycleGateWaiters[taskID], !waiters.isEmpty else {
            taskLifecycleGateOwners.remove(taskID)
            return
        }

        let next = waiters.removeFirst()
        if waiters.isEmpty {
            taskLifecycleGateWaiters.removeValue(forKey: taskID)
        } else {
            taskLifecycleGateWaiters[taskID] = waiters
        }
        next.continuation.resume(returning: true)
    }
}
