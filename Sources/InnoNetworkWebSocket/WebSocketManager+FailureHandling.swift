import Foundation
import InnoNetwork

// Split out of `WebSocketManager.swift` so failure routing — mapped/
// session errors, reconnect-context resolution, terminal cleanup, and
// the generation/identity helpers those depend on — lives in one place.
// All methods stay actor-isolated; this file only relocates code, no
// behaviour changes.
extension WebSocketManager {

    func handleMappedError(taskIdentifier: Int, error: WebSocketError) async {
        guard let task = await runtimeRegistry.webSocketTask(for: taskIdentifier) else { return }
        await handleFailure(
            task: task,
            generation: await callbackGeneration(for: taskIdentifier, fallbackTask: task),
            closeDisposition: .transportFailure(error)
        )
    }

    func handleFailure(
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

    func callbackGeneration(
        for taskIdentifier: Int,
        fallbackTask task: WebSocketTask
    ) async -> Int {
        if let generation = await runtimeRegistry.connectionGeneration(for: taskIdentifier) {
            return generation
        }
        return await task.connectionGeneration
    }

    func finishTerminalLifecycle(_ task: WebSocketTask, generation: Int) async {
        await finishTerminalTaskIfCurrent(task, generation: generation)
    }

    func finishTerminalTaskIfCurrent(_ task: WebSocketTask, generation: Int) async {
        guard await isCurrentTerminalTask(task, generation: generation) else { return }
        await eventHub.finish(taskID: task.id)
        // Re-check after suspension: a reconnect can revive this task while
        // `eventHub.finish` is awaiting subscriber cleanup.
        guard await isCurrentTerminalTask(task, generation: generation) else { return }
        await runtimeRegistry.remove(task)
    }

    func isCurrentTerminalTask(_ task: WebSocketTask, generation: Int) async -> Bool {
        guard await isCurrentConnection(task, generation: generation) else { return false }
        return await task.state.isTerminal
    }

    func isCurrentConnection(_ task: WebSocketTask, generation: Int) async -> Bool {
        await task.connectionGeneration == generation
    }
}
