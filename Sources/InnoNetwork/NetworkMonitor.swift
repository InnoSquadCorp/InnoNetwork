import Foundation
import Network


/// 네트워크 연결에 사용되는 인터페이스 유형입니다.
public enum NetworkInterfaceType: String, Sendable {
    /// Wi-Fi 연결입니다.
    case wifi
    /// 셀룰러 네트워크 연결입니다.
    case cellular
    /// 유선 이더넷 연결입니다.
    case wiredEthernet
    /// 로컬 루프백 인터페이스입니다.
    case loopback
    /// 알려진 유형으로 판별되지 않은 인터페이스입니다.
    case other
}

/// 네트워크 도달 가능 상태를 나타냅니다.
public enum NetworkReachabilityStatus: Sendable {
    /// 네트워크에 도달 가능합니다.
    case satisfied
    /// 네트워크에 도달 불가능합니다.
    case unsatisfied
    /// 네트워크에 도달하려면 추가 연결이 필요합니다.
    case requiresConnection
}

/// 특정 시점의 네트워크 상태를 나타내는 스냅샷입니다.
public struct NetworkSnapshot: Sendable, Equatable {
    /// 도달 가능 상태입니다.
    public let status: NetworkReachabilityStatus
    /// 사용 중인 인터페이스 유형 집합입니다.
    public let interfaceTypes: Set<NetworkInterfaceType>

    /// 지정한 상태와 인터페이스 유형으로 스냅샷을 생성합니다.
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

/// 네트워크 상태를 관찰하기 위한 프로토콜입니다.
/// - Note: 스냅샷은 아직 경로 업데이트를 받지 못했을 때 `nil`일 수 있습니다.
/// - Important: `waitForChange(from:timeout:)`의 `timeout`이 `nil`이면 변화가 감지될 때까지 대기합니다.
public protocol NetworkMonitoring: Sendable {
    /// 현재 네트워크 상태 스냅샷을 반환합니다.
    /// - Returns: 아직 관찰된 경로가 없으면 `nil`을 반환합니다.
    func currentSnapshot() async -> NetworkSnapshot?
    /// 지정한 스냅샷과 다른 상태로 변경될 때까지 대기합니다.
    /// - Parameters:
    ///   - snapshot: 기준이 되는 스냅샷입니다.
    ///   - timeout: `nil`이면 변화가 있을 때까지 대기하며, 값이 있으면 해당 시간 내 변화가 없을 경우 `nil`을 반환합니다.
    /// - Returns: 변화가 감지되면 새 스냅샷을, 타임아웃이면 `nil`을 반환합니다.
    func waitForChange(from snapshot: NetworkSnapshot?, timeout: TimeInterval?) async -> NetworkSnapshot?
}

/// `NWPathMonitor` 기반의 네트워크 모니터입니다.
/// - Note: `shared`는 앱 전역에서 재사용 가능한 싱글턴 인스턴스를 제공합니다.
public actor NetworkMonitor: NetworkMonitoring {
    public static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var current: NetworkSnapshot?
    private var continuations: [UUID: AsyncStream<NetworkSnapshot>.Continuation] = [:]
    private var isMonitoring = false

    public init() {
        monitor = NWPathMonitor()
        queue = DispatchQueue(label: "com.innonetwork.networkmonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.update(with: path) }
        }
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

    private func startMonitoringIfNeeded() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.start(queue: queue)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
