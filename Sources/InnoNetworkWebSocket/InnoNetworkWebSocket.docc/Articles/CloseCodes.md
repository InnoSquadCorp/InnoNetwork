# Close codes

Pattern-match on ``WebSocketCloseCode`` to drive reconnect, observability, and user-facing
recovery decisions.

## Overview

WebSocket connections close with a 16-bit code defined by RFC 6455. The library's
``WebSocketCloseCode`` exposes the full standard range (1000–1015) plus a typed escape
hatch for application-defined codes (3000–4999) so you can switch on the result without
parsing magic numbers.

## RFC 6455 codes

| Code | Case | Meaning |
|------|------|---------|
| 1000 | ``WebSocketCloseCode/normalClosure`` | Clean shutdown. |
| 1001 | ``WebSocketCloseCode/goingAway`` | Endpoint is leaving (page unload, server restart). |
| 1002 | ``WebSocketCloseCode/protocolError`` | Frame violated the protocol. |
| 1003 | ``WebSocketCloseCode/unsupportedData`` | Received data we cannot accept (text on a binary-only socket). |
| 1005 | ``WebSocketCloseCode/noStatusReceived`` | Reserved — no status was actually sent. |
| 1006 | ``WebSocketCloseCode/abnormalClosure`` | Reserved — connection lost without a close frame. |
| 1007 | ``WebSocketCloseCode/invalidFramePayloadData`` | Frame bytes were not consistent with the type (e.g., bad UTF-8). |
| 1008 | ``WebSocketCloseCode/policyViolation`` | Generic policy violation. |
| 1009 | ``WebSocketCloseCode/messageTooBig`` | Frame exceeds limits. |
| 1010 | ``WebSocketCloseCode/mandatoryExtension`` | Server did not negotiate a required extension. |
| 1011 | ``WebSocketCloseCode/internalServerError`` | Server crashed or hit an unexpected condition. |
| 1012 | ``WebSocketCloseCode/serviceRestart`` | Server is restarting. |
| 1013 | ``WebSocketCloseCode/tryAgainLater`` | Server is overloaded. |
| 1014 | ``WebSocketCloseCode/badGateway`` | Upstream gateway error. |
| 1015 | ``WebSocketCloseCode/tlsHandshakeFailure`` | Reserved — TLS handshake failed. |

> Foundation's `URLSessionWebSocketTask.CloseCode` omits `1012` and `1013`. The library's
> enum includes them as first-class cases so application servers that send them can be
> matched without falling into `.custom(_)`.

## Application-defined codes

`3000–3999` is reserved by IANA for libraries and frameworks; `4000–4999` is reserved for
private application use. Both ranges are represented as ``WebSocketCloseCode/custom(_:)``:

```swift
let suspended: WebSocketCloseCode = .custom(4001)

await WebSocketManager.shared.disconnect(task, closeCode: suspended)
```

Codes outside the 1000–4999 range are rejected at construction time — `init(rawValue:)`
returns `nil`.

## Pattern matching

Switch exhaustively to make the policy explicit:

```swift
switch await task.closeCode {
case .normalClosure?, .goingAway?:
    // Expected — do not retry.
    break

case .internalServerError?, .serviceRestart?, .tryAgainLater?, .badGateway?:
    // Retryable server-side condition.
    scheduleReconnect()

case .protocolError?, .unsupportedData?, .invalidFramePayloadData?, .policyViolation?:
    // Caller's fault. Surface to the user; do not retry blindly.
    surfaceTerminalFailure()

case .custom(let code)?:
    handleApplicationCode(code)

case nil:
    // Closed without a code (very rare in URLSession).
    break

default:
    scheduleReconnect()
}
```

The default ``WebSocketCloseDisposition`` classification already implements the standard
mapping; pattern-matching is what you reach for when an application-defined code needs
custom handling.

## Tooling

When debugging, log the close code as the raw value to make it greppable in dashboards:

```swift
let raw = (await task.closeCode)?.rawValue ?? -1
logger.info("websocket closed", metadata: ["code": .stringConvertible(raw)])
```

## Related

- ``WebSocketCloseCode``
- ``WebSocketCloseDisposition``
- <doc:Reconnect>
