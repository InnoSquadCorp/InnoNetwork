import Foundation
import InnoNetwork
import InnoNetworkWebSocket


// MARK: - CLI argument / env parsing

/// Default endpoint used when no URL argument is supplied. `ws.postman-echo.com`
/// is a commonly-available echo endpoint for manual testing. If it is
/// unavailable, pass a different `wss://` URL as the first CLI argument.
private let defaultURLString = "wss://ws.postman-echo.com/raw"

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment

let rawURLString: String = arguments.count > 1 ? arguments[1] : defaultURLString
let runIntegration = environment["INNONETWORK_RUN_INTEGRATION"] == "1"

guard let url = URL(string: rawURLString), url.scheme == "ws" || url.scheme == "wss" else {
    FileHandle.standardError.write(Data("Usage: WebSocketChat [ws(s)://host/path]\n".utf8))
    exit(2)
}


// MARK: - Guarded entry point

// The sample only opens a real connection when `INNONETWORK_RUN_INTEGRATION=1`.
// Without the env var it prints usage + configuration and exits `0`, so the
// example can still be covered by `swift build` in CI without pulling in
// network dependencies during the build.
guard runIntegration else {
    let note = """
    WebSocketChat sample
    --------------------
    Target endpoint: \(url.absoluteString)

    Set INNONETWORK_RUN_INTEGRATION=1 to actually connect, read stdin,
    and echo server responses. Example:

        INNONETWORK_RUN_INTEGRATION=1 swift run WebSocketChat
        INNONETWORK_RUN_INTEGRATION=1 swift run WebSocketChat wss://my.server/ws

    Leaving the env var unset is expected in CI — the sample exits 0 here.

    """
    FileHandle.standardOutput.write(Data(note.utf8))
    exit(0)
}


// MARK: - Live chat loop

let manager = WebSocketManager(
    configuration: .safeDefaults()
)

// RTT observability via the 5.0 `setOnPongHandler(_:)` callback.
// The same context is also available on the `.pong(_:)` event stream;
// we pick the callback here to keep the stdin loop simple.
await manager.setOnPongHandler { _, context in
    let totalSeconds = Double(context.roundTrip.components.seconds) +
        Double(context.roundTrip.components.attoseconds) / 1_000_000_000_000_000_000
    let millis = totalSeconds * 1_000
    FileHandle.standardOutput.write(
        Data("↔︎ pong attempt=\(context.attemptNumber) rtt=\(String(format: "%.1f", millis))ms\n".utf8)
    )
}

await manager.setOnErrorHandler { _, error in
    FileHandle.standardError.write(
        Data("⚠️  error: \(error)\n".utf8)
    )
}

let task = await manager.connect(url: url)

// Stream incoming events in a dedicated task. Prints text/binary messages
// and exits the program on disconnect.
let eventTask = Task {
    for await event in await manager.events(for: task) {
        switch event {
        case .connected(let subprotocol):
            print("✓ connected subprotocol=\(subprotocol ?? "<none>")")
        case .disconnected(let error):
            if let error {
                print("✗ disconnected: \(error)")
            } else {
                print("✗ disconnected")
            }
            return
        case .message(let data):
            print("← \(data.count) bytes")
        case .string(let text):
            print("← \(text)")
        case .ping(let context):
            print("→ ping attempt=\(context.attemptNumber)")
        case .pong(let context):
            // Event-stream path — duplicates the callback above for
            // demonstration. In production code you would pick one surface.
            _ = context
        case .error(let wsError):
            print("⚠︎ event-stream error: \(wsError)")
        @unknown default:
            break
        }
    }
}

// Read stdin line-by-line and forward each line as a string frame.
print("Type messages and press Enter. Ctrl-D to disconnect.")
while let line = readLine(strippingNewline: true) {
    do {
        try await manager.send(task, string: line)
        print("→ \(line)")
    } catch {
        print("⚠︎ send failed: \(error)")
        break
    }
}

await manager.disconnect(task, closeCode: .normalClosure)
await eventTask.value
