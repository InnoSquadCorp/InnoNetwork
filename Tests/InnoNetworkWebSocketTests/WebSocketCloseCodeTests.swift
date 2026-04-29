import Foundation
import Testing

@testable import InnoNetworkWebSocket

@Suite("WebSocket CloseCode Enum Tests")
struct WebSocketCloseCodeTests {

    @Test(
        "Raw value round-trip covers all RFC 6455 standard codes",
        arguments: [
            (UInt16(1000), WebSocketCloseCode.normalClosure),
            (UInt16(1001), .goingAway),
            (UInt16(1002), .protocolError),
            (UInt16(1003), .unsupportedData),
            (UInt16(1005), .noStatusReceived),
            (UInt16(1006), .abnormalClosure),
            (UInt16(1007), .invalidFramePayloadData),
            (UInt16(1008), .policyViolation),
            (UInt16(1009), .messageTooBig),
            (UInt16(1010), .mandatoryExtensionMissing),
            (UInt16(1011), .internalServerError),
            (UInt16(1012), .serviceRestart),
            (UInt16(1013), .tryAgainLater),
            (UInt16(1014), .badGateway),
            (UInt16(1015), .tlsHandshakeFailure),
        ]
    )
    func rawValueRoundTrip(rawValue: UInt16, expected: WebSocketCloseCode) {
        let decoded = WebSocketCloseCode(rawValue: rawValue)
        #expect(decoded == expected)
        #expect(decoded.rawValue == rawValue)
    }

    @Test(
        "Values outside 1000-1015 fall back to .custom",
        arguments: [UInt16(0), 1004, 1016, 2000, 3000, 4000, 4999]
    )
    func customFallback(rawValue: UInt16) {
        let decoded = WebSocketCloseCode(rawValue: rawValue)
        #expect(decoded == .custom(rawValue))
        #expect(decoded.rawValue == rawValue)
    }

    @Test("Bridging from URLSessionWebSocketTask.CloseCode preserves raw value")
    func bridgeFromURLSessionCloseCode() {
        let normal = WebSocketCloseCode(URLSessionWebSocketTask.CloseCode.normalClosure)
        #expect(normal == .normalClosure)

        let policy = WebSocketCloseCode(URLSessionWebSocketTask.CloseCode.policyViolation)
        #expect(policy == .policyViolation)
    }

    @Test("urlSessionCloseCode preserves raw value across the bridge")
    func urlSessionBridgePreservesRawValue() {
        // Even codes without a Swift case (1012/1013/1014) survive the bridge
        // because NSURLSessionWebSocketCloseCode is built from the raw integer.
        #expect(WebSocketCloseCode.serviceRestart.urlSessionCloseCode.rawValue == 1012)
        #expect(WebSocketCloseCode.tryAgainLater.urlSessionCloseCode.rawValue == 1013)
        #expect(WebSocketCloseCode.badGateway.urlSessionCloseCode.rawValue == 1014)

        // Representable codes round-trip cleanly.
        #expect(WebSocketCloseCode.normalClosure.urlSessionCloseCode == .normalClosure)
        #expect(WebSocketCloseCode.policyViolation.urlSessionCloseCode == .policyViolation)
    }
}


@Suite("WebSocket Close Disposition Classification Tests")
struct WebSocketCloseDispositionClassificationTests {

    @Test("Normal closure classifies as peerNormal")
    func normalClosureIsPeerNormal() {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            .normalClosure,
            reason: "bye"
        )
        switch disposition {
        case .peerNormal(let code, let reason):
            #expect(code == .normalClosure)
            #expect(reason == "bye")
        default:
            Issue.record("Expected .peerNormal, got \(disposition)")
        }
    }

    @Test(
        "Retryable peer codes classify as peerRetryable",
        arguments: [
            WebSocketCloseCode.goingAway,
            .abnormalClosure,
            .internalServerError,
            .serviceRestart,
            .tryAgainLater,
            .badGateway,
            .tlsHandshakeFailure,
        ]
    )
    func retryableClassification(code: WebSocketCloseCode) {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(code, reason: nil)
        switch disposition {
        case .peerRetryable:
            #expect(disposition.shouldReconnect)
        default:
            Issue.record("Expected .peerRetryable for \(code), got \(disposition)")
        }
    }

    @Test(
        "Terminal peer codes classify as peerTerminal",
        arguments: [
            WebSocketCloseCode.unsupportedData,
            .invalidFramePayloadData,
            .policyViolation,
            .messageTooBig,
            .mandatoryExtensionMissing,
            .protocolError,
            .noStatusReceived,
        ]
    )
    func terminalClassification(code: WebSocketCloseCode) {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(code, reason: nil)
        switch disposition {
        case .peerTerminal:
            #expect(!disposition.shouldReconnect)
        default:
            Issue.record("Expected .peerTerminal for \(code), got \(disposition)")
        }
    }

    @Test(
        "Custom close codes classify as peerTerminal",
        arguments: [UInt16(3000), 3999, 4000, 4999, 2500]
    )
    func customCodeIsTerminal(rawValue: UInt16) {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            .custom(rawValue),
            reason: nil
        )
        switch disposition {
        case .peerTerminal:
            #expect(!disposition.shouldReconnect)
        default:
            Issue.record("Expected .peerTerminal for custom(\(rawValue)), got \(disposition)")
        }
    }

    @Test("Foundation-bridged close codes classify identically to the typed enum")
    func foundationBridgeMatchesTypedEnum() {
        // Every stdlib-expressible case should classify the same way when it
        // arrives via the SessionDelegate Foundation boundary (which converts
        // to `WebSocketCloseCode` via `init(_ URLSessionWebSocketTask.CloseCode)`).
        let cases: [URLSessionWebSocketTask.CloseCode] = [
            .normalClosure, .goingAway, .protocolError, .unsupportedData,
            .noStatusReceived, .abnormalClosure, .invalidFramePayloadData,
            .policyViolation, .messageTooBig, .mandatoryExtensionMissing,
            .internalServerError, .tlsHandshakeFailure,
        ]

        for stdlibCode in cases {
            let viaBridge = WebSocketCloseDisposition.classifyPeerClose(
                WebSocketCloseCode(stdlibCode),
                reason: "r"
            )
            let viaDirect = WebSocketCloseDisposition.classifyPeerClose(
                WebSocketCloseCode(rawValue: UInt16(stdlibCode.rawValue)),
                reason: "r"
            )
            #expect(viaBridge == viaDirect, "Mismatch for \(stdlibCode)")
        }
    }

    @Test(
        "Custom raw values survive classification as .peerTerminal without truncation",
        arguments: [UInt16(2500), 3000, 4000, 4999]
    )
    func customRawValuePreservesInClassification(rawValue: UInt16) {
        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            .custom(rawValue),
            reason: "custom"
        )

        switch disposition {
        case .peerTerminal(let returnedCode, let reason):
            #expect(returnedCode.rawValue == rawValue)
            #expect(reason == "custom")
        default:
            Issue.record("Expected .peerTerminal for custom(\(rawValue)), got \(disposition)")
        }
    }
}


@Suite("WebSocket Handshake Disposition Classification Tests")
struct WebSocketHandshakeDispositionClassificationTests {

    @Test(
        "Handshake HTTP auth failures map to terminal dispositions",
        arguments: [
            (401, "unauthorized"),
            (403, "forbidden"),
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
            URLError.secureConnectionFailed,
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
