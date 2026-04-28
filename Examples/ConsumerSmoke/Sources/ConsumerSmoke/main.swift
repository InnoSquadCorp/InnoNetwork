import Foundation
import InnoNetwork
import InnoNetworkDownload
import InnoNetworkWebSocket

private struct ConsumerUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct ConsumerRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ConsumerUser

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}


// MARK: - Core configuration smoke

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)
_ = client
_ = ConsumerRequest()
_ = DownloadConfiguration.safeDefaults(sessionIdentifier: "com.example.consumer.downloads")
_ = WebSocketConfiguration.safeDefaults()


// MARK: - WebSocket public API smoke
//
// These helpers never execute at runtime (they are unused). Their job is to
// fail compilation if the public API surface regresses — exhaustive
// switches, pattern matches, and associated-value shapes are all checked at
// build time. Keeping these in consumer-smoke catches accidental breaking
// changes that the library's own tests would miss because they use
// `@testable import`.

/// `WebSocketCloseCode` covers the full RFC 6455 space plus `.custom(_)`.
/// Consumers can switch exhaustively on the common retryable subset.
@Sendable private func smokeCloseCodeSwitch(_ code: WebSocketCloseCode?) {
    switch code {
    case .serviceRestart, .tryAgainLater:
        // 1012 / 1013 — Apple's stdlib enum cannot express these.
        break
    case .custom(4001):
        // Application-defined close codes in the 3000–4999 range.
        break
    case .normalClosure, .goingAway, .protocolError, .unsupportedData,
        .noStatusReceived, .abnormalClosure, .invalidFramePayloadData,
        .policyViolation, .messageTooBig, .mandatoryExtensionMissing,
        .internalServerError, .badGateway, .tlsHandshakeFailure,
        .custom, .none:
        break
    }
}

/// Future candidate: classified close dispositions can branch UX on retryable
/// vs. terminal outcomes without re-implementing the mapping.
@Sendable private func smokeCloseDisposition(_ disposition: WebSocketCloseDisposition?) {
    switch disposition {
    case .manual(let code):
        _ = code
    case .peerNormal(let code, let reason),
        .peerRetryable(let code, let reason),
        .peerTerminal(let code, let reason):
        _ = code
        _ = reason
    case .handshakeUnauthorized(let status),
        .handshakeForbidden(let status),
        .handshakeServerUnavailable(let status),
        .handshakeTerminalHTTP(let status):
        _ = status
    case .handshakeTransientNetwork(let error):
        _ = error
    case .handshakeTimeout(let code):
        _ = code
    case .transportFailure(let error):
        _ = error
    case .none:
        break
    @unknown default:
        // Forward compatible with minor releases.
        break
    }

    _ = disposition?.shouldReconnect
}

/// Future candidate: `.ping` and `.pong` context payloads expose heartbeat
/// attempt and RTT metadata while preserving non-binding switch patterns.
@Sendable private func smokeEventObservation(_ event: WebSocketEvent) {
    switch event {
    case .connected(let subprotocol):
        _ = subprotocol
    case .disconnected(let error):
        _ = error
    case .message(let data):
        _ = data.count
    case .string(let text):
        _ = text
    case .ping(let context):
        _ = context.attemptNumber
        _ = context.dispatchedAt
    case .pong(let context):
        _ = context.attemptNumber
        _ = context.roundTrip
    case .error(let wsError):
        _ = wsError
    @unknown default:
        break
    }
}

/// Future candidate: consumers can opt into pong RTT metadata via
/// `setOnPongHandler(_:)`.
@Sendable private func smokePongHandler(_ manager: WebSocketManager) async {
    await manager.setOnPongHandler { task, context in
        _ = task.id
        _ = context.attemptNumber
        _ = context.roundTrip
    }
    await manager.setOnPongHandler(nil)
}

_ = smokeCloseCodeSwitch
_ = smokeCloseDisposition
_ = smokeEventObservation
_ = smokePongHandler

print("ConsumerSmoke OK")
