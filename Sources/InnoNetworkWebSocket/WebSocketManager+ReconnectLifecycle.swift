import Foundation
import InnoNetwork

// Reconnect and close-handshake timeout scheduling are kept together because
// both own generation-scoped runtime workers and re-enter the lifecycle reducer.
extension WebSocketManager {

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
