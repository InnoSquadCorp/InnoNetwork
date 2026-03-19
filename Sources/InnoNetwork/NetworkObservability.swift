import Foundation
import OSLog


public enum NetworkEvent: Sendable {
    case requestStart(
        requestID: UUID,
        method: String,
        url: String,
        retryIndex: Int
    )
    case requestAdapted(
        requestID: UUID,
        method: String,
        url: String,
        retryIndex: Int
    )
    case responseReceived(
        requestID: UUID,
        statusCode: Int,
        byteCount: Int
    )
    case retryScheduled(
        requestID: UUID,
        retryIndex: Int,
        delay: TimeInterval,
        reason: String
    )
    case requestFinished(
        requestID: UUID,
        statusCode: Int,
        byteCount: Int
    )
    case requestFailed(
        requestID: UUID,
        errorCode: Int,
        message: String
    )
}

/// Receives request lifecycle events emitted by the networking client.
public protocol NetworkEventObserving: Sendable {
    func handle(_ event: NetworkEvent) async
}

/// An observer that intentionally ignores all events.
public struct NoOpNetworkEventObserver: NetworkEventObserving {
    public init() {}

    public func handle(_ event: NetworkEvent) async {
        _ = event
    }
}

/// An observer that mirrors request lifecycle events to `OSLog`.
public struct OSLogNetworkEventObserver: NetworkEventObserving {
    public init() {}

    public func handle(_ event: NetworkEvent) async {
        #if DEBUG
        switch event {
        case .requestStart(let requestID, let method, let url, let retryIndex):
            Logger.API.debug("request_start id=\(requestID.uuidString, privacy: .public) method=\(method, privacy: .public) url=\(url, privacy: .private) retryIndex=\(retryIndex)")
        case .requestAdapted(let requestID, let method, let url, let retryIndex):
            Logger.API.debug("request_adapted id=\(requestID.uuidString, privacy: .public) method=\(method, privacy: .public) url=\(url, privacy: .private) retryIndex=\(retryIndex)")
        case .responseReceived(let requestID, let statusCode, let byteCount):
            Logger.API.debug("response_received id=\(requestID.uuidString, privacy: .public) status=\(statusCode) bytes=\(byteCount)")
        case .retryScheduled(let requestID, let retryIndex, let delay, let reason):
            Logger.API.info("retry_scheduled id=\(requestID.uuidString, privacy: .public) retryIndex=\(retryIndex) delay=\(delay, privacy: .public)s reason=\(reason, privacy: .private)")
        case .requestFinished(let requestID, let statusCode, let byteCount):
            Logger.API.info("request_finished id=\(requestID.uuidString, privacy: .public) status=\(statusCode) bytes=\(byteCount)")
        case .requestFailed(let requestID, let errorCode, let message):
            Logger.API.error("request_failed id=\(requestID.uuidString, privacy: .public) code=\(errorCode) message=\(message, privacy: .private)")
        }
        #endif
    }
}

public struct NetworkRequestContext: Sendable {
    public let requestID: UUID
    public let retryIndex: Int
    public let metricsReporter: (any NetworkMetricsReporting)?
    public let trustPolicy: TrustPolicy
    public let eventObservers: [any NetworkEventObserving]

    public init(
        requestID: UUID = UUID(),
        retryIndex: Int = 0,
        metricsReporter: (any NetworkMetricsReporting)? = nil,
        trustPolicy: TrustPolicy = .systemDefault,
        eventObservers: [any NetworkEventObserving] = []
    ) {
        self.requestID = requestID
        self.retryIndex = retryIndex
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
    }
}
