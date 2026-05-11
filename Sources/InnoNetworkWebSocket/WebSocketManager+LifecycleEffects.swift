import Foundation
import InnoNetwork

// Split out of `WebSocketManager.swift` so the lifecycle-effect executor
// — the reducer-effect interpreter plus the connection / close-handshake
// / reconnect entry points it delegates to — lives in one place. All
// methods stay actor-isolated; this file only relocates code, no
// behaviour changes.
extension WebSocketManager {

    func startConnection(_ task: WebSocketTask) async {
        guard !isShutdown else { return }
        let transition = await task.applyLifecycleEvent(.connect)
        await executeLifecycleEffects(transition.effects, for: task)
    }

    func finishTaskBecauseManagerIsShutdown(_ task: WebSocketTask) async {
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

    func startTransportConnection(_ task: WebSocketTask) async {
        guard !isShutdown else { return }
        if configuration.permessageDeflateEnabled {
            await failUnsupportedURLSessionFeature(.permessageDeflate, for: task)
            return
        }
        await connectionCoordinator.startConnection(task) { [weak self] taskIdentifier, error in
            self?.handleError(taskIdentifier: taskIdentifier, error: error)
        }
    }

    func failUnsupportedURLSessionFeature(
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

    func executeLifecycleEffects(
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

    func scheduleCloseHandshakeTimeout(
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

    func publishPong(task: WebSocketTask, context: WebSocketPongContext) async {
        await runtimeRegistry.onPong?(task, context)
        await eventHub.publish(.pong(context), for: task.id)
    }

    func startReconnecting(_ task: WebSocketTask) async {
        let transition = await task.applyLifecycleEvent(.reconnectTimerFired)
        await executeLifecycleEffects(transition.effects, for: task)
    }

    func handleCloseHandshakeTimeout(
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
}
