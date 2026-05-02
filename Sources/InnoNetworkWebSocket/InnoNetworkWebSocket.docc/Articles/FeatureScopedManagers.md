# Feature-scoped managers

Prefer constructing a ``WebSocketManager`` for each feature boundary instead of sharing one
process-wide singleton.

## Overview

``WebSocketManager/shared`` remains available in 4.0.0 for source compatibility, but it is
soft-deprecated. A single global manager forces unrelated realtime flows to share reconnect,
heartbeat, send-buffer, event-buffer, and metrics settings. Feature-scoped managers keep
those policies close to the socket owner.

```swift
import InnoNetworkWebSocket

struct ChatSocket {
    private let manager: WebSocketManager

    init() {
        let configuration = WebSocketConfiguration.advanced { builder in
            builder.heartbeatInterval = 20
            builder.pongTimeout = 5
            builder.sendQueueLimit = 32
        }
        self.manager = WebSocketManager(configuration: configuration)
    }

    func connect(userID: String) async -> WebSocketTask {
        await manager.connect(
            url: URL(string: "wss://chat.example.com/users/\(userID)")!
        )
    }
}
```

Use one manager when the app has one realtime policy. Use multiple managers when a feature
needs a different heartbeat cadence, reconnect budget, event delivery policy, or test
session injection.

## Related

- ``WebSocketManager``
- ``WebSocketConfiguration``
- <doc:Reconnect>
