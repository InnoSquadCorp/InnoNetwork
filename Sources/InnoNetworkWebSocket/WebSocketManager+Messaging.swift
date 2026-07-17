import Foundation

extension WebSocketManager {
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
}
