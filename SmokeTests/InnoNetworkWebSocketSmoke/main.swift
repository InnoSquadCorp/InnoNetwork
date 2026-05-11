import Foundation
import InnoNetwork
import InnoNetworkWebSocket

// MARK: - InnoNetworkWebSocketSmoke
//
// Integration smoke that exercises the real URLSession-backed
// `WebSocketManager.connect/send/disconnect` path end-to-end against
// a public echo server. Gated behind `INNONETWORK_RUN_INTEGRATION=1`
// so offline CI runs of `swift build` stay unaffected.
//
// Scenario:
//   1. Connect to the supplied wss:// URL.
//   2. Send a plain-text frame.
//   3. Wait for the echoed message.
//   4. Disconnect with a normal close code and exit.
//
// Exit code 0 on success, 1 on failure, 0 when skipped (no env flag).

private let environment = ProcessInfo.processInfo.environment
private let runIntegration = environment["INNONETWORK_RUN_INTEGRATION"] == "1"
private let arguments = CommandLine.arguments
private let urlString: String? = arguments.count > 1 ? arguments[1] : nil

guard runIntegration else {
    let note = """
        InnoNetworkWebSocketSmoke skipped (INNONETWORK_RUN_INTEGRATION != 1).
        Set the flag and provide an explicit WSS URL to exercise the
        connect/send/echo path:

            INNONETWORK_RUN_INTEGRATION=1 swift run InnoNetworkWebSocketSmoke \\
                wss://echo.websocket.events

        """
    FileHandle.standardOutput.write(Data(note.utf8))
    exit(0)
}

guard let urlString else {
    FileHandle.standardError.write(
        Data(
            "Usage: INNONETWORK_RUN_INTEGRATION=1 swift run InnoNetworkWebSocketSmoke [wss://host/path]\n".utf8
        )
    )
    exit(2)
}

guard let url = URL(string: urlString), url.scheme?.lowercased() == "wss" else {
    FileHandle.standardError.write(Data("Invalid WSS URL: \(urlString)\n".utf8))
    exit(1)
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

let configuration = WebSocketConfiguration.advanced { builder in
    builder.heartbeatInterval = 15
    builder.maxReconnectAttempts = 0
}

let manager = WebSocketManager(configuration: configuration)
let task = await manager.connect(url: url)
let events = await manager.events(for: task)
let payload = "innonetwork-smoke-\(UUID().uuidString)"

print("▶︎ connect    \(url.absoluteString)")
print("            payload = \(payload)")

var sawEcho = false

eventLoop: for await event in events {
    switch event {
    case .connected(let proto):
        print("   connected (subprotocol = \(proto ?? "<none>"))")
        do {
            try await manager.send(task, string: payload)
            print("   sent text frame")
        } catch {
            fail("send failed: \(error)")
        }
    case .string(let received):
        guard received == payload else {
            print("   ignored non-matching string frame")
            continue
        }
        sawEcho = true
        print("✓ echo received")
        await manager.disconnect(task, closeCode: .normalClosure)
    case .message(let data):
        print("   ignored binary frame (\(data.count) bytes)")
    case .error(let webSocketError):
        fail("websocket error: \(webSocketError)")
    case .disconnected:
        break eventLoop
    case .ping, .pong, .sendDropped:
        continue
    }
}

guard sawEcho else {
    fail("event stream closed before echo arrived")
}

print("InnoNetworkWebSocketSmoke OK")
