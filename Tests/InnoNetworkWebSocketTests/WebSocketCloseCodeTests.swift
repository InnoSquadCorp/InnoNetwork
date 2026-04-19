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

    @Test("Stdlib CloseCode overload matches typed enum results")
    func stdlibOverloadMatchesTypedEnum() {
        // All stdlib-expressible cases must produce the same disposition shape
        // whichever overload the caller uses.
        let cases: [URLSessionWebSocketTask.CloseCode] = [
            .normalClosure, .goingAway, .protocolError, .unsupportedData,
            .noStatusReceived, .abnormalClosure, .invalidFramePayloadData,
            .policyViolation, .messageTooBig, .mandatoryExtensionMissing,
            .internalServerError, .tlsHandshakeFailure,
        ]

        for stdlibCode in cases {
            let viaStdlib = WebSocketCloseDisposition.classifyPeerClose(
                closeCode: stdlibCode,
                reason: "r"
            )
            let viaTyped = WebSocketCloseDisposition.classifyPeerClose(
                WebSocketCloseCode(stdlibCode),
                reason: "r"
            )
            #expect(viaStdlib == viaTyped, "Mismatch for \(stdlibCode)")
        }
    }

    @Test(
        "Stdlib CloseCode overload preserves raw value for custom peer close codes",
        arguments: [Int(2500), 3000, 4000, 4999]
    )
    func stdlibOverloadPreservesCustomRawValue(rawValue: Int) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: rawValue)
        #expect(closeCode != nil)

        let disposition = WebSocketCloseDisposition.classifyPeerClose(
            closeCode: closeCode ?? .invalid,
            reason: "custom"
        )

        switch disposition {
        case .peerTerminal(let returnedCode, let reason):
            #expect(returnedCode.rawValue == rawValue)
            #expect(reason == "custom")
        default:
            Issue.record("Expected .peerTerminal for custom raw value \(rawValue), got \(disposition)")
        }
    }
}
