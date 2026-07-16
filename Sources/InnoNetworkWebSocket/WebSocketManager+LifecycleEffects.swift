import Foundation
import InnoNetwork

// The reducer-effect interpreter and the connection, close-handshake, and
// reconnect entry points it delegates to live together here. All methods stay
// actor-isolated on `WebSocketManager`.
extension WebSocketManager {

    func startConnection(_ task: WebSocketTask) async {
        guard !isShutdown else { return }
        await acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        let transition = await task.applyLifecycleEvent(.connect)
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }

    func finishTaskBecauseManagerIsShutdown(_ task: WebSocketTask) async {
        await acquireTaskLifecycleGateUnconditionally(taskID: task.id)

        let error = Self.managerShutdownError()
        let transition = await task.applyLifecycleEvent(.managerShutdown(error: error))
        let callbacks = await executeLifecycleEffects(
            transition.effects,
            for: task,
            expectedGeneration: transition.state.generation,
            lifecycleGateAlreadyHeld: true
        )
        await closeEventConsumerAdmissionAndWait(taskID: task.id)
        defer { reopenEventConsumerAdmission(taskID: task.id) }
        await runtimeRegistry.removeTaskRuntime(taskId: task.id)
        await eventHub.finishAndWaitForClosure(taskID: task.id)
        await runtimeRegistry.remove(task)
        releaseTaskLifecycleGate(taskID: task.id)
        await executeDeferredUserCallbacks(callbacks)
    }

    func startTransportConnection(_ task: WebSocketTask) async {
        guard !isShutdown else { return }
        if configuration.permessageDeflateEnabled {
            await failUnsupportedURLSessionFeature(.permessageDeflate, for: task)
            return
        }
        let prepared: WebSocketPreparedConnection
        switch await connectionCoordinator.prepareConnection(task) {
        case .prepared(let connection):
            prepared = connection
        case .cancelled:
            return
        case .failed(let generation, let underlying):
            await failHandshakeRequestAdaptation(
                for: task,
                generation: generation,
                underlying: underlying
            )
            return
        }

        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        defer { releaseTaskLifecycleGate(taskID: task.id) }

        guard await isCurrentTransportCandidate(task, generation: prepared.generation) else { return }
        await runtimeRegistry.cancelHeartbeatTask(for: task.id)
        // The heartbeat cancellation suspends. Revalidate on the manager actor
        // immediately before synchronously creating the Foundation task so a
        // terminal transition that won that interval cannot create transport.
        guard await isCurrentTransportCandidate(task, generation: prepared.generation) else { return }
        guard let urlTask = makeWebSocketTaskIfRunning(with: prepared.request) else { return }
        urlTask.maximumMessageSize = configuration.maximumMessageSize
        delegate.registerRedirectProtectedHeaderNames(
            prepared.request.allHTTPHeaderFields?.keys ?? [:].keys,
            for: urlTask.taskIdentifier
        )
        await runtimeRegistry.setMapping(
            webSocketTask: task,
            for: urlTask.taskIdentifier,
            generation: prepared.generation
        )
        await runtimeRegistry.setURLTask(urlTask, for: task.id)

        // Mapping is installed before resume so synchronous delegate delivery
        // can resolve the task. Revalidate after those actor hops; stale tasks
        // are detached and cancelled without ever being resumed.
        guard await isCurrentTransportCandidate(task, generation: prepared.generation) else {
            delegate.removeRedirectProtectedHeaderNames(for: urlTask.taskIdentifier)
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
            return
        }
        guard resumeWebSocketTaskIfRunning(urlTask) else {
            delegate.removeRedirectProtectedHeaderNames(for: urlTask.taskIdentifier)
            await runtimeRegistry.removeTaskRuntime(taskId: task.id)
            return
        }
        await receiveLoop.start(
            task: task,
            urlTask: urlTask,
            onEvent: { [weak self] event in
                await self?.publishReceiveEventIfCurrent(
                    event,
                    task: task,
                    generation: prepared.generation,
                    urlTask: urlTask
                )
            },
            onError: { [weak self] taskIdentifier, error in
                self?.handleError(taskIdentifier: taskIdentifier, error: error)
            }
        )
    }

    /// Routes a throwing handshake adapter through the same generation-aware
    /// reducer path as URLSession transport failures. No Foundation task exists
    /// yet, so this path validates the logical task directly rather than looking
    /// up a transport callback mapping.
    func failHandshakeRequestAdaptation(
        for task: WebSocketTask,
        generation: Int,
        underlying: SendableUnderlyingError
    ) async {
        await acquireTaskLifecycleGateUnconditionally(taskID: task.id)

        guard await isCurrentTransportCandidate(task, generation: generation) else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }

        let error = WebSocketError.connectionFailed(underlying)
        let disposition = WebSocketCloseDisposition.transportFailure(error)
        let reconnectAction = await reconnectCoordinator.reconnectAction(
            task: task,
            closeDisposition: disposition
        )
        let transition = await task.applyLifecycleEvent(
            .failure(
                generation: generation,
                disposition: disposition,
                error: error
            ),
            context: .init(
                reconnectAction: reconnectAction,
                attempt: await task.attemptedReconnectCount
            )
        )
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }

    func isCurrentTransportCandidate(_ task: WebSocketTask, generation: Int) async -> Bool {
        guard !isShutdown else { return false }
        guard let registeredTask = await runtimeRegistry.task(withId: task.id), registeredTask === task else {
            return false
        }
        return await task.isConnecting(generation: generation)
    }

    func makeWebSocketTaskIfRunning(with request: URLRequest) -> (any WebSocketURLTask)? {
        shutdownLock.withLock { shutdownStarted in
            guard !shutdownStarted else { return nil }
            return session.makeWebSocketTask(with: request)
        }
    }

    func resumeWebSocketTaskIfRunning(_ task: any WebSocketURLTask) -> Bool {
        shutdownLock.withLock { shutdownStarted in
            guard !shutdownStarted else { return false }
            task.resume()
            return true
        }
    }

    func failUnsupportedURLSessionFeature(
        _ feature: WebSocketProtocolFeature,
        for task: WebSocketTask
    ) async {
        await acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        let error = WebSocketError.unsupportedProtocolFeature(feature)
        let transition = await task.applyLifecycleEvent(
            .failure(
                generation: await task.connectionGeneration,
                disposition: .transportFailure(error),
                error: error
            ),
            context: .init(reconnectAction: .terminal)
        )
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }

    /// Completes an apply/effect transaction whose lifecycle event was
    /// committed while this task's gate was already held. Terminal effects
    /// retain that gate through publication and partition closure, then defer
    /// manager callbacks until after release; nonterminal effects release it
    /// before invoking callbacks so reentrant operations can honor their
    /// normal async completion boundary without waiting on an outer callback.
    func executeLifecycleEffectsAfterLockedApply(
        _ transition: WebSocketLifecycleTransition,
        for task: WebSocketTask
    ) async {
        let effects = transition.effects
        let isTerminal = effects.contains { effect in
            if case .finishTerminal = effect { return true }
            return false
        }
        if isTerminal {
            let callbacks = await executeLifecycleEffects(
                effects,
                for: task,
                expectedGeneration: transition.state.generation,
                lifecycleGateAlreadyHeld: true
            )
            releaseTaskLifecycleGate(taskID: task.id)
            await executeDeferredUserCallbacks(callbacks)
        } else {
            _ = await executeLifecycleEffects(
                effects,
                for: task,
                expectedGeneration: transition.state.generation,
                lifecycleGateAlreadyHeld: true,
                releaseNonterminalLifecycleGate: true
            )
        }
    }

    private func executeLifecycleEffects(
        _ effects: [WebSocketLifecycleEffect],
        for task: WebSocketTask,
        expectedGeneration: Int? = nil,
        lifecycleGateAlreadyHeld: Bool = false,
        releaseNonterminalLifecycleGate: Bool = false
    ) async -> [WebSocketPreparedUserCallback] {
        let effectGeneration: Int
        if let expectedGeneration {
            effectGeneration = expectedGeneration
        } else {
            effectGeneration = await task.connectionGeneration
        }
        let terminalGeneration = effects.lazy.compactMap { effect -> Int? in
            guard case .finishTerminal(let generation) = effect else { return nil }
            return generation
        }.first
        let finalTerminalPublicationIndex: Int? =
            terminalGeneration == nil
            ? nil
            : effects.indices.last { index in
                switch effects[index] {
                case .publishDisconnected, .publishError, .publishTerminalError:
                    true
                default:
                    false
                }
            }
        let acquiredTerminalLifecycleGate = terminalGeneration != nil && !lifecycleGateAlreadyHeld
        if let terminalGeneration, acquiredTerminalLifecycleGate {
            await acquireTaskLifecycleGateUnconditionally(taskID: task.id)
            guard await isCurrentTerminalTask(task, generation: terminalGeneration) else {
                releaseTaskLifecycleGate(taskID: task.id)
                return []
            }
        }
        var deferredUserCallbacks: [WebSocketPreparedUserCallback] = []
        var holdsNonterminalLifecycleGate =
            releaseNonterminalLifecycleGate
            && lifecycleGateAlreadyHeld
            && terminalGeneration == nil

        func releaseNonterminalLifecycleGateIfNeeded() {
            guard holdsNonterminalLifecycleGate else { return }
            holdsNonterminalLifecycleGate = false
            releaseTaskLifecycleGate(taskID: task.id)
        }

        defer {
            releaseNonterminalLifecycleGateIfNeeded()
            if acquiredTerminalLifecycleGate {
                releaseTaskLifecycleGate(taskID: task.id)
            }
        }

        for (effectIndex, effect) in effects.enumerated() {
            switch effect {
            case .startConnection(generation: _):
                // Transport preparation can invoke user handshake adapters and
                // startTransportConnection owns its own validation gate.
                releaseNonterminalLifecycleGateIfNeeded()
                await startTransportConnection(task)
            case .startHeartbeat:
                await heartbeatCoordinator.startHeartbeat(
                    for: task,
                    onPingTimeout: { [weak self] taskIdentifier in
                        self?.handlePingTimeout(taskIdentifier: taskIdentifier)
                    },
                    onPing: { [weak self] task, urlTask in
                        guard let self else { return nil }
                        return await self.admitHeartbeatPingIfCurrent(
                            task: task,
                            generation: effectGeneration,
                            urlTask: urlTask
                        )
                    },
                    onPong: { [weak self] task, urlTask, context in
                        await self?.publishHeartbeatPongIfCurrent(
                            task: task,
                            generation: effectGeneration,
                            urlTask: urlTask,
                            context: context
                        )
                    },
                    onPingError: { [weak self] task, urlTask, error in
                        guard let self else { return false }
                        return await self.publishHeartbeatErrorIfCurrent(
                            task: task,
                            generation: effectGeneration,
                            urlTask: urlTask,
                            error: error
                        )
                    }
                )
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
                let callback = await runtimeRegistry.prepareConnectedCallback(
                    task,
                    protocolName: protocolName
                )
                await eventHub.publish(.connected(protocolName), for: task.id)
                releaseNonterminalLifecycleGateIfNeeded()
                await runtimeRegistry.invokePreparedUserCallback(callback)
            case .publishDisconnected(let error):
                if terminalGeneration != nil {
                    // Snapshot and admit the handler before the publication
                    // actor hop. The manager can reenter while that enqueue is
                    // suspended; a handler installed afterwards must not
                    // receive historical terminal work.
                    if let callback = await runtimeRegistry.prepareDisconnectedCallback(
                        task,
                        error: error
                    ) {
                        deferredUserCallbacks.append(callback)
                    }
                    if effectIndex == finalTerminalPublicationIndex {
                        await eventHub.publishTerminalAndWaitForEnqueue(.disconnected(error), for: task.id)
                    } else {
                        await eventHub.publishAndWaitForEnqueue(.disconnected(error), for: task.id)
                    }
                } else {
                    let callback = await runtimeRegistry.prepareDisconnectedCallback(
                        task,
                        error: error
                    )
                    await eventHub.publishAndWaitForEnqueue(.disconnected(error), for: task.id)
                    releaseNonterminalLifecycleGateIfNeeded()
                    await runtimeRegistry.invokePreparedUserCallback(callback)
                }
            case .publishError(let error):
                if terminalGeneration != nil {
                    if let callback = await runtimeRegistry.prepareErrorCallback(
                        task,
                        error: error
                    ) {
                        deferredUserCallbacks.append(callback)
                    }
                    if effectIndex == finalTerminalPublicationIndex {
                        await eventHub.publishTerminalAndWaitForEnqueue(.error(error), for: task.id)
                    } else {
                        await eventHub.publishAndWaitForEnqueue(.error(error), for: task.id)
                    }
                } else {
                    let callback = await runtimeRegistry.prepareErrorCallback(
                        task,
                        error: error
                    )
                    await eventHub.publishAndWaitForEnqueue(.error(error), for: task.id)
                    releaseNonterminalLifecycleGateIfNeeded()
                    await runtimeRegistry.invokePreparedUserCallback(callback)
                }
            case .publishTerminalError(let error):
                if let callback = await runtimeRegistry.prepareErrorCallback(
                    task,
                    error: error
                ) {
                    deferredUserCallbacks.append(callback)
                }
                if effectIndex == finalTerminalPublicationIndex {
                    await eventHub.publishTerminalAndWaitForEnqueue(.error(error), for: task.id)
                } else {
                    await eventHub.publishAndWaitForEnqueue(.error(error), for: task.id)
                }
            case .scheduleReconnect:
                releaseNonterminalLifecycleGateIfNeeded()
                await scheduleReconnectIfCurrent(task, generation: effectGeneration)
            case .finishTerminal(let generation):
                if lifecycleGateAlreadyHeld || acquiredTerminalLifecycleGate {
                    await finishTerminalTaskIfCurrentHoldingLifecycleGate(
                        task,
                        generation: generation
                    )
                } else {
                    await finishTerminalLifecycle(task, generation: generation)
                }
            case .ignoreStaleCallback:
                break
            }
        }
        return deferredUserCallbacks
    }

    private func executeDeferredUserCallbacks(
        _ callbacks: [WebSocketPreparedUserCallback]
    ) async {
        for callback in callbacks {
            await runtimeRegistry.invokePreparedUserCallback(callback)
        }
    }

    func scheduleReconnectIfCurrent(_ task: WebSocketTask, generation: Int) async {
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        defer { releaseTaskLifecycleGate(taskID: task.id) }
        guard !isShutdown,
            let registeredTask = await runtimeRegistry.task(withId: task.id),
            registeredTask === task,
            await task.connectionGeneration == generation,
            await task.state == .reconnecting
        else { return }

        await reconnectCoordinator.attemptReconnect(task: task) { [weak self] task in
            await self?.startReconnecting(task, expectedGeneration: generation)
        }
    }

    func scheduleCloseHandshakeTimeout(
        for task: WebSocketTask,
        closeCode: WebSocketCloseCode
    ) async {
        guard let urlTask = await runtimeRegistry.urlTask(for: task.id) else { return }
        // URLSession demands its own close-code enum at the cancel() call,
        // so convert at the Foundation boundary.
        urlTask.cancel(with: closeCode.urlSessionCloseCode, reason: nil)
        let closeHandshakeTimeout = configuration.closeHandshakeTimeout
        let taskID = task.id
        let generation = await task.connectionGeneration
        let clock = self.clock
        let workerID = UUID()
        let closeTimeoutTask = Task { [weak self, taskID, clock, urlTask] in
            await WebSocketRuntimeWorkerContext.$workerID.withValue(workerID) {
                do {
                    try await clock.sleep(for: closeHandshakeTimeout)
                } catch is CancellationError {
                    return
                } catch {
                    // A scheduler failure must not silently remove the only bound
                    // on listener teardown. Fail closed and force the same terminal
                    // path as an elapsed close-handshake deadline.
                }
                await self?.handleCloseHandshakeTimeout(
                    taskID: taskID,
                    closeCode: closeCode,
                    expectedGeneration: generation,
                    expectedURLTask: urlTask
                )
            }
        }
        await runtimeRegistry.setCloseHandshakeTask(closeTimeoutTask, workerID: workerID, for: taskID)
    }

    func startReconnecting(_ task: WebSocketTask, expectedGeneration: Int? = nil) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }

        let generation: Int
        if let expectedGeneration {
            generation = expectedGeneration
        } else {
            generation = await task.connectionGeneration
        }
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        guard let registeredTask = await runtimeRegistry.task(withId: task.id),
            registeredTask === task,
            await task.connectionGeneration == generation,
            await task.state == .reconnecting
        else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }
        let transition = await task.applyLifecycleEvent(.reconnectTimerFired)
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }

    func handleCloseHandshakeTimeout(
        taskID: String,
        closeCode: WebSocketCloseCode,
        expectedGeneration: Int? = nil,
        expectedURLTask: (any WebSocketURLTask)? = nil
    ) async {
        guard beginShutdownTrackedOperation() else { return }
        defer { finishShutdownTrackedOperation() }

        guard let task = await runtimeRegistry.task(withId: taskID) else { return }
        let generation: Int
        if let expectedGeneration {
            generation = expectedGeneration
        } else {
            generation = await task.connectionGeneration
        }
        let urlTask: (any WebSocketURLTask)?
        if let expectedURLTask {
            urlTask = expectedURLTask
        } else {
            urlTask = await runtimeRegistry.urlTask(for: taskID)
        }
        // Cancel only the transport captured by this timeout generation before
        // waiting for the lifecycle gate. Foundation receive() may ignore
        // Swift Task cancellation; closing the transport is what lets manual
        // disconnect finish its pre-callback worker drain and release the gate.
        urlTask?.cancel()
        guard await acquireTaskLifecycleGate(taskID: task.id) else { return }
        let expectedURLTaskIsCurrent: Bool
        if let expectedURLTask {
            expectedURLTaskIsCurrent = await runtimeRegistry.urlTask(for: taskID) === expectedURLTask
        } else {
            expectedURLTaskIsCurrent = true
        }
        guard !Task.isCancelled,
            let registeredTask = await runtimeRegistry.task(withId: taskID),
            registeredTask === task,
            await task.connectionGeneration == generation,
            expectedURLTaskIsCurrent,
            await task.awaitingCloseHandshake
        else {
            releaseTaskLifecycleGate(taskID: task.id)
            return
        }

        // The timeout worker removes only its own registry slot. If terminal
        // cleanup already detached it, this is a no-op and cannot clear a
        // newer generation's close worker.
        await runtimeRegistry.clearCloseHandshakeTask(for: taskID)
        let finalError = makeDisconnectedError(
            closeDisposition: .handshakeTimeout(closeCode)
        )
        let transition = await task.applyLifecycleEvent(
            .closeTimeout(closeCode: closeCode, error: finalError)
        )
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }
}
