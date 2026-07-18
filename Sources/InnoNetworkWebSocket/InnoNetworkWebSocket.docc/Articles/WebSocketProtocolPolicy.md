# WebSocket protocol policy

Pick subprotocols, frame compression, and heartbeat tuning that match the
server's expectations rather than relying on `URLSessionWebSocketTask`
defaults.

## Subprotocol negotiation

The HTTP `Sec-WebSocket-Protocol` request header advertises which
application-level subprotocols the client supports; the server picks
exactly one. Pass the list to ``WebSocketManager/connect(url:subprotocols:)``
and validate the negotiated value once the `.connected` event arrives:

```swift
let manager = WebSocketManager(configuration: configuration)
let task = await manager.connect(url: url, subprotocols: ["chat.v2", "chat.v1"])

for await event in await manager.events(for: task) {
    switch event {
    case .connected(let negotiated):
        guard negotiated == "chat.v2" else {
            await manager.disconnect(task)
            return
        }
    default:
        break
    }
}
```

Two operational rules:

- Order the array by preference. The server is required to echo back a
  value the client advertised, but is free to pick any of them.
- Use protocol identifiers only; never place credentials or secret-bearing
  tokens in a subprotocol value. `Sec-WebSocket-Protocol` is a required
  handshake field and is therefore preserved across admitted secure
  cross-origin redirects.
- Treat an unexpected echo as a hard policy failure rather than a
  transport error — the connection negotiated successfully, but the
  application contract is wrong. Disconnect with a client-policy close
  reason and surface a categorized error to the caller.

## Redirect admission and origin trust

The built-in URLSession transport re-admits every handshake redirect before
following it. The default contract permits any structurally valid secure `wss`
target, including a different origin; it does not maintain a trusted-origin
allowlist. Only connect to an endpoint whose redirect authorities are part of
the same trust boundary.

For a cross-origin redirect, InnoNetwork removes every caller-prepared request
header, including authorization and application-specific values. It preserves
only fields CFNetwork needs to complete the WebSocket handshake, including the
subprotocol negotiation field described above. Credential decisions remain
bound to the original handshake origin across every hop. A `wss` handshake can
never downgrade to `ws`, even when plain WebSocket transport was explicitly
enabled for an initial URL. An invalid, traversing, ambiguous, or downgraded
redirect is terminal and does not schedule automatic reconnect.

## App-level protocol failure mapping

When the application protocol layered on top of WebSocket frames
(JSON-RPC, chat envelopes, signaling commands) reports a failure, map
it to a ``WebSocketCloseCode`` that the server's reconnect policy will
recognize:

| App-level cause                       | Recommended close code                  |
|---------------------------------------|-----------------------------------------|
| Malformed application message         | ``WebSocketCloseCode/invalidFramePayloadData`` (1007) |
| Server policy rejection (e.g. quota)  | ``WebSocketCloseCode/policyViolation`` (1008) |
| Application-version mismatch          | ``WebSocketCloseCode/internalError`` (1011) with reason |
| Client-initiated close (logout)       | ``WebSocketCloseCode/normalClosure`` (1000) |

Closing with a precise code lets reconnect logic on both sides
distinguish "transient transport hiccup, reconnect" from "application
protocol mismatch, do not reconnect". See <doc:CloseCodes> for the full
disposition mapping the manager uses to gate reconnect.

## Compression (deflate) on URLSession

`URLSessionWebSocketTask` does not implement `permessage-deflate`
(RFC 7692). Do not advertise compression in `Sec-WebSocket-Extensions`;
the server will either reject the handshake or assume frames are
deflated and corrupt them.

If `WebSocketMessagingPack(permessageDeflateEnabled: true)` is used with the
built-in URLSession transport, ``WebSocketManager`` fails the connection
before creating a socket and publishes
``WebSocketError/unsupportedProtocolFeature(_:)`` through the normal error
callback/event path. That makes compression misconfiguration
visible during rollout instead of silently opening an uncompressed connection.
Deployments that require compression should move to an optional transport that
can negotiate RFC 7692 end to end.

## Heartbeat tuning

`WebSocketLivenessPack(heartbeatInterval:)` (set to `0` to disable) governs
how often the manager sends a ping; the paired pong timeout
sits on the same configuration. Tune the two together rather than in
isolation:

- **Mobile foreground:** 30s ping interval, 10s pong timeout. Catches
  half-open connections (carrier NAT silently dropping the socket)
  without burning radio for keepalives.
- **Mobile background-eligible:** disable application heartbeats and
  lean on URLSession's own keepalive — the OS will not deliver
  application-layer pings reliably while suspended. Reconnect on
  resume instead.
- **Desktop / server-to-server:** 10s/3s. Tighter intervals are cheap
  on a wired link and shorten the time-to-detect for dead peers.

The manager surfaces every ping attempt as a `.ping` event and every
timeout as `.error(.pingTimeout)`, so application metrics can correlate
configuration choices with observed RTT and loss.
