import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

/// Historical reference suite — exercises the *policy* under which a
/// transport failure should (have) trigger `.error(.pingTimeout)`. Production
/// heartbeat now publishes `.pingTimeout` unconditionally on ANY send-ping
/// failure (see `WebSocketHeartbeatCoordinator`), so these cases assert
/// only the reference classifier defined locally below — they exist to
/// document which transport failures were always intended as terminal for
/// heartbeat. The unconditional production behavior is covered by the
/// broader heartbeat tests in `WebSocketLifecycleTests` /
/// `WebSocketReconnectBackoffTests`.
@Suite("WebSocket Heartbeat Classifier Reference Tests")
struct WebSocketHeartbeatHardeningTests {

    @Test("Reference classifier flags URLError.cannotConnectToHost as ping timeout")
    func cannotConnectToHostClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.cannotConnectToHost)))
    }

    @Test("Reference classifier flags URLError.networkConnectionLost as ping timeout")
    func networkConnectionLostClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.networkConnectionLost)))
    }

    @Test("Reference classifier flags URLError.notConnectedToInternet as ping timeout")
    func notConnectedToInternetClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.notConnectedToInternet)))
    }

    @Test("Reference classifier flags URLError.cancelled as ping timeout for heartbeat purposes")
    func cancelledClassifiedAsTimeout() {
        #expect(callIsPingTimeout(URLError(.cancelled)))
    }

    @Test("Reference classifier excludes unrelated URLError codes (production publishes regardless)")
    func unrelatedURLErrorIsNotTimeout() {
        // The reference classifier returns false for these; production
        // still publishes `.error(.pingTimeout)` on any send-ping failure.
        #expect(!callIsPingTimeout(URLError(.badURL)))
        #expect(!callIsPingTimeout(URLError(.userAuthenticationRequired)))
    }

    /// Reference classifier used as the historical contract for which
    /// transport failures should publish `.error(.pingTimeout)`. The
    /// production heartbeat now publishes unconditionally on any send-ping
    /// failure, but this table-driven coverage stays useful as a regression
    /// guard for the classification policy.
    private func callIsPingTimeout(_ error: Error) -> Bool {
        if let internalError = error as? WebSocketInternalError,
            case .pingTimeout = internalError
        {
            return true
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                .cannotConnectToHost,
                .networkConnectionLost,
                .notConnectedToInternet,
                .cancelled:
                return true
            default:
                return false
            }
        }
        return false
    }
}
