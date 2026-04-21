# WebSocketChat

Minimal CLI sample that opens a WebSocket connection, prints server-sent
frames, and forwards stdin lines as string frames. Exercises the 5.0
`WebSocketManager` surface end-to-end: `safeDefaults`, `connect(url:)`,
`events(for:)` stream consumption, `send(_:string:)`,
`setOnPongHandler(_:)` RTT observability, and `disconnect(_:closeCode:)`.

## Running

The sample gates real connections behind an environment variable so
`swift build` stays offline-safe in CI:

```bash
# Build only (no connection attempt)
swift build

# Run against the default endpoint (ws.postman-echo.com):
INNONETWORK_RUN_INTEGRATION=1 swift run WebSocketChat

# Override the endpoint:
INNONETWORK_RUN_INTEGRATION=1 swift run WebSocketChat wss://my.server/ws
```

Type messages and press Enter to send each line as a WebSocket text
frame. The default endpoint echoes every frame back, so you should see
`→ hello` on send and `← hello` on receive. Press `Ctrl-D` to close the
session cleanly (`.normalClosure`). Remote disconnects, handshake
failures, and terminal send failures exit non-zero instead of leaving
the sample blocked on stdin.

## Configuration

- `safeDefaults` — conservative heartbeat / reconnect tuning for
  interactive clients. This sample keeps that baseline but forces
  `maxReconnectAttempts = 0` so terminal connection failures exit
  promptly instead of retrying in the background.
- RTT is surfaced via `setOnPongHandler(_:)`. The same
  `WebSocketPongContext` is also delivered on the `.pong(_:)` event
  stream — pick whichever fits your codebase.

If the default echo endpoint is unreachable, pass any other `ws(s)://`
URL as the first argument.
