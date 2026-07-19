import Foundation

/// Actor-isolated coordination state owned exclusively by
/// ``WebSocketManager``. Keeping the related counters, admission fences, and
/// lifecycle-gate queues in one value makes their shared invariants explicit
/// without introducing another executor or lock.
struct WebSocketManagerCoordinationState {
    var activeShutdownTrackedOperationCount = 0
    var shutdownTrackedOperationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    var eventConsumerAdmissionClosedTaskIDs: Set<String> = []
    var activeEventConsumerRegistrationCounts: [String: Int] = [:]
    var eventConsumerRegistrationDrainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    var taskLifecycleGateOwners: Set<String> = []
    var taskLifecycleGateWaiters: [String: [TaskLifecycleGateWaiter]] = [:]
}

struct TaskLifecycleGateWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}
