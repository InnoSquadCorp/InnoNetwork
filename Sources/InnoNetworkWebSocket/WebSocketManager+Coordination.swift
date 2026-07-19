import Foundation

extension WebSocketManager {
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
        coordinationState.activeShutdownTrackedOperationCount += 1
        return true
    }

    func finishShutdownTrackedOperation() {
        coordinationState.activeShutdownTrackedOperationCount -= 1
        guard coordinationState.activeShutdownTrackedOperationCount == 0 else { return }
        let waiters = coordinationState.shutdownTrackedOperationDrainWaiters
        coordinationState.shutdownTrackedOperationDrainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForShutdownTrackedOperationsToDrain() async {
        guard coordinationState.activeShutdownTrackedOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            coordinationState.shutdownTrackedOperationDrainWaiters.append(continuation)
        }
    }

    func beginEventConsumerRegistration(taskID: String) -> Bool {
        guard !coordinationState.eventConsumerAdmissionClosedTaskIDs.contains(taskID) else { return false }
        coordinationState.activeEventConsumerRegistrationCounts[taskID, default: 0] += 1
        return true
    }

    func finishEventConsumerRegistration(taskID: String) {
        guard let activeCount = coordinationState.activeEventConsumerRegistrationCounts[taskID], activeCount > 0
        else { return }
        if activeCount > 1 {
            coordinationState.activeEventConsumerRegistrationCounts[taskID] = activeCount - 1
            return
        }

        coordinationState.activeEventConsumerRegistrationCounts.removeValue(forKey: taskID)
        let waiters = coordinationState.eventConsumerRegistrationDrainWaiters.removeValue(forKey: taskID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func closeEventConsumerAdmissionAndWait(taskID: String) async {
        coordinationState.eventConsumerAdmissionClosedTaskIDs.insert(taskID)
        guard coordinationState.activeEventConsumerRegistrationCounts[taskID, default: 0] > 0 else { return }
        await withCheckedContinuation { continuation in
            coordinationState.eventConsumerRegistrationDrainWaiters[taskID, default: []].append(continuation)
        }
    }

    func reopenEventConsumerAdmission(taskID: String) {
        coordinationState.eventConsumerAdmissionClosedTaskIDs.remove(taskID)
    }

    func isEventConsumerAdmissionClosed(taskID: String) -> Bool {
        coordinationState.eventConsumerAdmissionClosedTaskIDs.contains(taskID)
    }

    /// Acquires the per-task lifecycle gate while remaining responsive to
    /// cancellation. Runtime workers are cancelled and drained by terminal
    /// cleanup; a cancelled worker must be able to leave this queue instead
    /// of waiting for the cleanup-owned gate and forming a circular wait.
    func acquireTaskLifecycleGate(taskID: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        if coordinationState.taskLifecycleGateOwners.insert(taskID).inserted {
            guard !Task.isCancelled else {
                coordinationState.taskLifecycleGateOwners.remove(taskID)
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
                coordinationState.taskLifecycleGateWaiters[taskID, default: []].append(
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
        guard !coordinationState.taskLifecycleGateOwners.insert(taskID).inserted else { return }
        _ = await withCheckedContinuation { continuation in
            coordinationState.taskLifecycleGateWaiters[taskID, default: []].append(
                TaskLifecycleGateWaiter(id: UUID(), continuation: continuation)
            )
        }
    }

    func cancelTaskLifecycleGateWaiter(taskID: String, waiterID: UUID) {
        guard var waiters = coordinationState.taskLifecycleGateWaiters[taskID],
            let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }

        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            coordinationState.taskLifecycleGateWaiters.removeValue(forKey: taskID)
        } else {
            coordinationState.taskLifecycleGateWaiters[taskID] = waiters
        }
        waiter.continuation.resume(returning: false)
    }

    func taskLifecycleGateWaiterCount(taskID: String) -> Int {
        coordinationState.taskLifecycleGateWaiters[taskID]?.count ?? 0
    }

    func releaseTaskLifecycleGate(taskID: String) {
        guard var waiters = coordinationState.taskLifecycleGateWaiters[taskID], !waiters.isEmpty else {
            coordinationState.taskLifecycleGateOwners.remove(taskID)
            return
        }

        let next = waiters.removeFirst()
        if waiters.isEmpty {
            coordinationState.taskLifecycleGateWaiters.removeValue(forKey: taskID)
        } else {
            coordinationState.taskLifecycleGateWaiters[taskID] = waiters
        }
        next.continuation.resume(returning: true)
    }
}
