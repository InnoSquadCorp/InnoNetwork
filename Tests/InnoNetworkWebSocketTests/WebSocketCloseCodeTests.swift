import Foundation
import Testing
@testable import InnoNetworkWebSocket


@Suite("WebSocket Close Code Classification Tests")
struct WebSocketCloseCodeTests {

    @Test("1000 (normalClosure) classifies as peerNormal")
    func normalClosureIsPeerNormal() {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            closeCode: .normalClosure,
            reason: "bye"
        )
        #expect(disposition == .peerNormal(.normalClosure, "bye"))
        #expect(!disposition.shouldReconnect)
    }

    @Test("goingAway (1001) classifies as peerRetryable")
    func goingAwayIsPeerRetryable() {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            closeCode: .goingAway,
            reason: nil
        )
        #expect(disposition == .peerRetryable(.goingAway, nil))
        #expect(disposition.shouldReconnect)
    }

    @Test(
        "Retryable close codes classify as peerRetryable",
        arguments: [
            URLSessionWebSocketTask.CloseCode.goingAway,
            .abnormalClosure,
            .internalServerError,
            .tlsHandshakeFailure
        ]
    )
    func retryableCloseCodesClassifyAsPeerRetryable(_ closeCode: URLSessionWebSocketTask.CloseCode) {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            closeCode: closeCode,
            reason: nil
        )
        if case .peerRetryable = disposition {
            #expect(disposition.shouldReconnect)
        } else {
            Issue.record("Expected peerRetryable for \(closeCode.rawValue), got \(disposition)")
        }
    }

    @Test(
        "Terminal close codes classify as peerTerminal",
        arguments: [
            URLSessionWebSocketTask.CloseCode.unsupportedData,
            .invalidFramePayloadData,
            .policyViolation,
            .messageTooBig
        ]
    )
    func terminalCloseCodesClassifyAsPeerTerminal(_ closeCode: URLSessionWebSocketTask.CloseCode) {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            closeCode: closeCode,
            reason: nil
        )
        if case .peerTerminal = disposition {
            #expect(!disposition.shouldReconnect)
        } else {
            Issue.record("Expected peerTerminal for \(closeCode.rawValue), got \(disposition)")
        }
    }

    @Test("Unknown close codes classify as peerTerminal")
    func unknownCloseCodeIsPeerTerminal() {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            closeCode: .mandatoryExtensionMissing,
            reason: nil
        )
        if case .peerTerminal = disposition {
            #expect(!disposition.shouldReconnect)
        } else {
            Issue.record("Expected peerTerminal for mandatoryExtensionMissing")
        }
    }

    @Test(
        "Handshake HTTP auth failures map to terminal dispositions",
        arguments: [
            (401, "unauthorized"),
            (403, "forbidden")
        ]
    )
    func handshakeAuthIsTerminal(_ args: (Int, String)) {
        let (statusCode, _) = args
        let disposition = WebSocketCloseDisposition.classifyHandshake(
            statusCode: statusCode,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.userAuthenticationRequired.rawValue,
                message: "auth"
            )
        )
        #expect(!disposition.shouldReconnect)
    }

    @Test(
        "Handshake server unavailable codes are retryable",
        arguments: [429, 500, 502, 503, 504, 599]
    )
    func handshakeServerUnavailableIsRetryable(_ statusCode: Int) {
        let disposition = WebSocketCloseDisposition.classifyHandshake(
            statusCode: statusCode,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.badServerResponse.rawValue,
                message: "server"
            )
        )
        if case .handshakeServerUnavailable = disposition {
            #expect(disposition.shouldReconnect)
        } else {
            Issue.record("Expected handshakeServerUnavailable for \(statusCode)")
        }
    }

    @Test(
        "Handshake terminal HTTP codes do not reconnect",
        arguments: [400, 404, 410, 422]
    )
    func handshakeTerminalHTTPIsTerminal(_ statusCode: Int) {
        let disposition = WebSocketCloseDisposition.classifyHandshake(
            statusCode: statusCode,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: URLError.badServerResponse.rawValue,
                message: "\(statusCode)"
            )
        )
        if case .handshakeTerminalHTTP = disposition {
            #expect(!disposition.shouldReconnect)
        } else {
            Issue.record("Expected handshakeTerminalHTTP for \(statusCode)")
        }
    }

    @Test(
        "Transient network errors classify as handshakeTransientNetwork",
        arguments: [
            URLError.timedOut,
            URLError.notConnectedToInternet,
            URLError.networkConnectionLost,
            URLError.cannotFindHost,
            URLError.cannotConnectToHost,
            URLError.dnsLookupFailed,
            URLError.secureConnectionFailed
        ]
    )
    func transientNetworkErrorsClassifyAsRetryable(_ code: URLError.Code) {
        let disposition = WebSocketCloseDisposition.classifyHandshake(
            statusCode: nil,
            error: SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: code.rawValue,
                message: "transient"
            )
        )
        if case .handshakeTransientNetwork = disposition {
            #expect(disposition.shouldReconnect)
        } else {
            Issue.record("Expected handshakeTransientNetwork for code \(code.rawValue)")
        }
    }

    @Test("Non-URL-domain error without status code maps to transportFailure")
    func nonURLDomainErrorIsTransportFailure() {
        let disposition = WebSocketCloseDisposition.classifyHandshake(
            statusCode: nil,
            error: SendableUnderlyingError(
                domain: "UnknownDomain",
                code: 42,
                message: "weird"
            )
        )
        if case .transportFailure = disposition {
            #expect(disposition.shouldReconnect)
        } else {
            Issue.record("Expected transportFailure for non-URL domain error")
        }
    }
}
