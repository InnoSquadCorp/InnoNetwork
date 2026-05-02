import Foundation
@preconcurrency import Network
import os

private final class PathMonitorStorage: Sendable {
    private let queue: DispatchQueue
    private let activeMonitor: OSAllocatedUnfairLock<NWPathMonitor?>

    init() {
        self.queue = DispatchQueue(label: "com.innonetwork.networkmonitor")
        self.activeMonitor = OSAllocatedUnfairLock(initialState: nil)
    }

    func makePathStream() -> AsyncStream<NWPath> {
        // `NWPathMonitor.cancel()` is terminal: a cancelled monitor cannot be
        // restarted. Recreate one per `makePathStream()` so that callers may
        // stop and re-start observation without leaking the prior instance.
        let monitor = NWPathMonitor()
        activeMonitor.withLock { $0 = monitor }
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { [monitor] continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
            continuation.onTermination = { _ in
                monitor.pathUpdateHandler = nil
            }
        }
    }

    func start() {
        let monitor = activeMonitor.withLock { $0 }
        monitor?.start(queue: queue)
    }

    func cancel() {
        let monitor = activeMonitor.withLock { state -> NWPathMonitor? in
            let snapshot = state
            state = nil
            return snapshot
        }
        monitor?.cancel()
    }
}


/// The type of network interface used for connectivity.
public enum NetworkInterfaceType: String, Sendable {
    /// Wi-Fi connection.
    case wifi
    /// Cellular network connection.
    case cellular
    /// Wired Ethernet connection.
    case wiredEthernet
    /// Local loopback interface.
    case loopback
    /// Interface type that could not be identified.
    case other
}

/// Represents the network reachability status.
public enum NetworkReachabilityStatus: Sendable {
    /// The network is reachable.
    case satisfied
    /// The network is not reachable.
    case unsatisfied
    /// Additional connection is required to reach the network.
    case requiresConnection
}

/// A snapshot representing the network state at a specific point in time.
public struct NetworkSnapshot: Sendable, Equatable {
    /// The reachability status.
    public let status: NetworkReachabilityStatus
    /// The set of interface types currently in use.
    public let interfaceTypes: Set<NetworkInterfaceType>

    /// Creates a snapshot with the specified status and interface types.
    public init(status: NetworkReachabilityStatus, interfaceTypes: Set<NetworkInterfaceType>) {
        self.status = status
        self.interfaceTypes = interfaceTypes
    }

    init(path: NWPath) {
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .unsatisfied:
            status = .unsatisfied
        case .requiresConnection:
            status = .requiresConnection
        @unknown default:
            status = .unsatisfied
        }

        var types: Set<NetworkInterfaceType> = []
        if path.usesInterfaceType(.wifi) { types.insert(.wifi) }
        if path.usesInterfaceType(.cellular) { types.insert(.cellular) }
        if path.usesInterfaceType(.wiredEthernet) { types.insert(.wiredEthernet) }
        if path.usesInterfaceType(.loopback) { types.insert(.loopback) }
        if types.isEmpty { types.insert(.other) }
        interfaceTypes = types
    }
}

/// Protocol for observing network state.
/// - Note: The snapshot may be `nil` when no path updates have been received yet.
/// - Important: If `timeout` in `waitForChange(from:timeout:)` is `nil`, it waits until a change is detected.
public protocol NetworkMonitoring: Sendable {
    /// Returns the current network state snapshot.
    /// - Returns: `nil` if no path has been observed yet.
    func currentSnapshot() async -> NetworkSnapshot?
    /// Waits until the network state changes from the specified snapshot.
    /// - Parameters:
    ///   - snapshot: The reference snapshot.
    ///   - timeout: If `nil`, waits indefinitely until a change occurs. If set, returns `nil` if no change within the timeout.
    /// - Returns: A new snapshot if a change is detected, or `nil` on timeout.
    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot?
}

/// A network monitor based on `NWPathMonitor`.
/// - Note: `shared` provides a singleton instance reusable across the app.
public actor NetworkMonitor: NetworkMonitoring {
    public static let shared = NetworkMonitor()

    private let pathMonitor: PathMonitorStorage
    private var current: NetworkSnapshot?
    private var continuations: [UUID: AsyncStream<NetworkSnapshot>.Continuation] = [:]
    private var isMonitoring = false
    private var pathConsumerTask: Task<Void, Never>?

    public init() {
        pathMonitor = PathMonitorStorage()
    }

    deinit {
        pathConsumerTask?.cancel()
        pathMonitor.cancel()
    }

    /// Begin observing path updates. Calling this before the first `currentSnapshot`
    /// or `waitForChange` lets callers control the moment the underlying
    /// `NWPathMonitor` is started — useful for tests, app-lifecycle integration,
    /// or deferring system observers until after launch. Repeat calls are
    /// idempotent.
    public func start() {
        startMonitoringIfNeeded()
    }

    /// Stop observing path updates and tear down the underlying `NWPathMonitor`
    /// and consumer task. Subsequent calls to `start()`, `currentSnapshot()`,
    /// or `waitForChange(...)` will resume monitoring with a fresh consumer.
    public func stop() {
        guard isMonitoring else { return }
        pathConsumerTask?.cancel()
        pathConsumerTask = nil
        pathMonitor.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        isMonitoring = false
    }

    public func currentSnapshot() async -> NetworkSnapshot? {
        startMonitoringIfNeeded()
        return current
    }

    public func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot? {
        startMonitoringIfNeeded()
        if let current, current != snapshot {
            return current
        }

        let stream = updates()
        return await withTaskGroup(of: NetworkSnapshot?.self) { group in
            group.addTask {
                for await update in stream where update != snapshot {
                    return update
                }
                return nil
            }
            if let timeout {
                group.addTask {
                    let safeTimeout = max(0, timeout)
                    try? await Task.sleep(for: .seconds(safeTimeout), clock: .suspending)
                    return nil
                }
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func updates() -> AsyncStream<NetworkSnapshot> {
        // Snapshots are state observations: a slow consumer should only ever
        // see the most recent path state, never a backlog. `.bufferingNewest`
        // keeps the latest snapshots and discards older ones under pressure.
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func update(with path: NWPath) {
        let snapshot = NetworkSnapshot(path: path)
        current = snapshot
        continuations.values.forEach { $0.yield(snapshot) }
    }

    private func startMonitoringIfNeeded() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Channelize NWPath callbacks through an AsyncStream so updates run
        // serially inside the actor instead of spawning a fresh Task per
        // emission. Under network flapping (elevators, transit, captive
        // portals) the previous design could pile up unbounded Tasks; this
        // back-pressured loop processes paths in arrival order. The buffer
        // is bounded so an unresponsive consumer cannot keep stale paths
        // alive indefinitely.
        let pathStream = pathMonitor.makePathStream()

        pathConsumerTask = Task { [weak self] in
            for await path in pathStream {
                guard let self else { return }
                await self.update(with: path)
            }
        }

        pathMonitor.start()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
