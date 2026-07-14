import Foundation
import InnoNetwork

// Split out of `WebSocketManager.swift` so failure routing — mapped/
// session errors, reconnect-context resolution, terminal cleanup, and
// the generation/identity helpers those depend on — lives in one place.
// All methods stay actor-isolated.
extension WebSocketManager {

    func handleMappedError(taskIdentifier: Int, error: WebSocketError) async {
        guard let callbackContext = await runtimeRegistry.callbackContext(for: taskIdentifier) else { return }
        await handleMappedError(
            error,
            callbackContext: callbackContext,
            taskIdentifier: taskIdentifier
        )
    }

    func handleMappedError(
        _ error: WebSocketError,
        callbackContext: WebSocketRuntimeCallbackContext,
        taskIdentifier: Int
    ) async {
        guard
            await acquireTaskLifecycleGate(
                for: callbackContext,
                taskIdentifier: taskIdentifier
            )
        else { return }
        await handleFailureHoldingLifecycleGate(
            callbackContext: callbackContext,
            closeDisposition: .transportFailure(error)
        )
    }

    func handleFailureHoldingLifecycleGate(
        callbackContext: WebSocketRuntimeCallbackContext,
        closeDisposition: WebSocketCloseDisposition,
        previousState: WebSocketState? = nil
    ) async {
        let task = callbackContext.task
        let finalError = makeFailureError(closeDisposition: closeDisposition)
        let currentGeneration = await task.connectionGeneration
        let currentState = await task.state
        let context: WebSocketLifecycleDecisionContext
        if callbackContext.generation != currentGeneration
            || currentState == .disconnecting
            || currentState.isTerminal
        {
            context = .init()
        } else {
            let reconnectAction = await reconnectCoordinator.reconnectAction(
                task: task,
                closeDisposition: closeDisposition,
                previousState: previousState
            )
            context = .init(
                reconnectAction: reconnectAction,
                attempt: await task.attemptedReconnectCount
            )
        }

        let transition = await task.applyLifecycleEvent(
            .failure(
                generation: callbackContext.generation,
                disposition: closeDisposition,
                error: finalError
            ),
            context: context
        )
        await executeLifecycleEffectsAfterLockedApply(transition, for: task)
    }

    /// Acquires the source task-ID transaction gate, then verifies that the
    /// delegate identifier still names the exact task and generation captured
    /// in the registry snapshot. Missing mappings are stale callbacks; they
    /// are never rebound to the task's mutable current generation.
    func acquireTaskLifecycleGate(
        for callbackContext: WebSocketRuntimeCallbackContext,
        taskIdentifier: Int
    ) async -> Bool {
        await acquireTaskLifecycleGateUnconditionally(taskID: callbackContext.task.id)
        guard
            await runtimeRegistry.matchesCallbackContext(
                callbackContext,
                for: taskIdentifier
            ),
            await callbackContext.task.connectionGeneration == callbackContext.generation
        else {
            releaseTaskLifecycleGate(taskID: callbackContext.task.id)
            return false
        }
        return true
    }

    func finishTerminalLifecycle(_ task: WebSocketTask, generation: Int) async {
        await finishTerminalTaskIfCurrent(task, generation: generation)
    }

    func finishTerminalTaskIfCurrent(_ task: WebSocketTask, generation: Int) async {
        await acquireTaskLifecycleGateUnconditionally(taskID: task.id)
        defer { releaseTaskLifecycleGate(taskID: task.id) }

        await finishTerminalTaskIfCurrentHoldingLifecycleGate(task, generation: generation)
    }

    /// Completes terminal partition cleanup while the caller owns this task's
    /// lifecycle gate. Terminal effect execution uses this form so retry cannot
    /// interleave between destructive runtime cleanup, terminal publication,
    /// and registry removal.
    func finishTerminalTaskIfCurrentHoldingLifecycleGate(
        _ task: WebSocketTask,
        generation: Int
    ) async {

        guard await isCurrentTerminalTask(task, generation: generation) else { return }
        await closeEventConsumerAdmissionAndWait(taskID: task.id)
        defer { reopenEventConsumerAdmission(taskID: task.id) }
        await eventHub.finishAndWaitForClosure(taskID: task.id)
        // Keep the defensive re-check even though explicit retry preparation
        // uses the same lifecycle gate. A stale terminal callback must never
        // remove a task that no longer matches its captured generation.
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
