import Foundation
import Network


public enum NetworkInterfaceType: String, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
}

public enum NetworkReachabilityStatus: Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

public struct NetworkSnapshot: Sendable, Equatable {
    public let status: NetworkReachabilityStatus
    public let interfaceTypes: Set<NetworkInterfaceType>

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

public protocol NetworkMonitoring: Sendable {
    func currentSnapshot() async -> NetworkSnapshot?
    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot?
}

public actor NetworkMonitor: NetworkMonitoring {
    public static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var current: NetworkSnapshot?
    private var continuations: [UUID: AsyncStream<NetworkSnapshot>.Continuation] = [:]

    public init() {
        monitor = NWPathMonitor()
        queue = DispatchQueue(label: "com.innonetwork.networkmonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.update(with: path) }
        }
        monitor.start(queue: queue)
    }

    public func currentSnapshot() async -> NetworkSnapshot? {
        current
    }

    public func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot? {
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
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func updates() -> AsyncStream<NetworkSnapshot> {
        AsyncStream { continuation in
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

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
