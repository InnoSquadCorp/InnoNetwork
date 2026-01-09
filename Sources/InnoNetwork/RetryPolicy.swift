import Foundation


public protocol RetryPolicy: Sendable {
    var maxRetries: Int { get }
    /// 네트워크 변화 등으로 재시도 카운트가 리셋되더라도, 총 재시도 횟수 상한을 제한합니다.
    var maxTotalRetries: Int { get }
    var retryDelay: TimeInterval { get }
    /// 재시도 시도 횟수에 따른 지연 시간(초)을 반환합니다.
    func retryDelay(for attempt: Int) -> TimeInterval
    func shouldRetry(error: NetworkError, attempt: Int) -> Bool
    var waitsForNetworkChanges: Bool { get }
    var networkChangeTimeout: TimeInterval? { get }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool
}

public extension RetryPolicy {
    var maxTotalRetries: Int { maxRetries }
    var waitsForNetworkChanges: Bool { false }
    var networkChangeTimeout: TimeInterval? { nil }
    func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool {
        false
    }

    func retryDelay(for attempt: Int) -> TimeInterval {
        retryDelay
    }
}

public struct ExponentialBackoffRetryPolicy: RetryPolicy {
    public let maxRetries: Int
    public let maxTotalRetries: Int
    public let retryDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterRatio: Double
    public let waitsForNetworkChanges: Bool
    public let networkChangeTimeout: TimeInterval?

    /// - Parameters:
    ///   - maxRetries: 최대 재시도 횟수입니다.
    ///   - maxTotalRetries: 재시도 카운트 리셋이 발생해도 허용되는 총 재시도 횟수 상한입니다.
    ///   - retryDelay: 기본 재시도 지연(초)입니다.
    ///   - maxDelay: 지수 백오프의 최대 지연(초)입니다.
    ///   - jitterRatio: 지연 시간에 적용할 지터 비율입니다. (예: 0.2는 ±20%, 음수 지터로 0 미만이 되면 0으로 클램프됨)
    ///   - waitsForNetworkChanges: 재시도 전 네트워크 변화 감지를 기다릴지 여부입니다.
    ///   - networkChangeTimeout: 네트워크 변화 대기 제한 시간입니다. `nil`이면 변화가 있을 때까지 대기합니다.
    public init(
        maxRetries: Int = 3,
        maxTotalRetries: Int? = nil,
        retryDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        jitterRatio: Double = 0.2,
        waitsForNetworkChanges: Bool = true,
        networkChangeTimeout: TimeInterval? = 10.0
    ) {
        self.maxRetries = maxRetries
        self.maxTotalRetries = maxTotalRetries ?? maxRetries
        self.retryDelay = retryDelay
        self.maxDelay = maxDelay
        self.jitterRatio = jitterRatio
        self.waitsForNetworkChanges = waitsForNetworkChanges
        self.networkChangeTimeout = networkChangeTimeout
    }

    public func shouldRetry(error: NetworkError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        switch error {
        case .statusCode(let response):
            return response.statusCode == 408
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
        case .nonHTTPResponse:
            return true
        case .underlying(let error, _):
            return !NetworkError.isCancellation(error)
        case .cancelled:
            return false
        default:
            return false
        }
    }

    public func retryDelay(for attempt: Int) -> TimeInterval {
        let exponent = pow(2.0, Double(max(attempt, 0)))
        let base = min(retryDelay * exponent, maxDelay)
        let jitter = abs(base * jitterRatio)
        let range = (-jitter)...(jitter)
        let randomOffset = Double.random(in: range)
        return max(0.0, base + randomOffset)
    }

    public func shouldResetAttempts(afterNetworkChangeFrom oldSnapshot: NetworkSnapshot?, to newSnapshot: NetworkSnapshot?) -> Bool {
        guard let oldSnapshot, let newSnapshot else { return false }
        return oldSnapshot.interfaceTypes != newSnapshot.interfaceTypes
            || oldSnapshot.status != newSnapshot.status
    }
}
