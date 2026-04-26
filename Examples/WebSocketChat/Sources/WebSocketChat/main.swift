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

private enum ChatTermination: Sendable {
    case userEOF
    case remoteDisconnect(WebSocketError?)
    case terminalFailure(WebSocketError)
    case sendFailure(String)
    case stdinFailure(String)
    case eventStreamEnded
}

private actor ChatShutdown {
    private var termination: ChatTermination?
    private var continuation: CheckedContinuation<ChatTermination, Never>?

    func finish(_ termination: ChatTermination) {
        guard self.termination == nil else { return }
        self.termination = termination
        continuation?.resume(returning: termination)
        continuation = nil
    }

    func wait() async -> ChatTermination {
        if let termination {
            return termination
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@Sendable
private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

let safeDefaults = WebSocketConfiguration.safeDefaults()
let manager = WebSocketManager(
    configuration: WebSocketConfiguration(
        maxConnectionsPerHost: safeDefaults.maxConnectionsPerHost,
        connectionTimeout: safeDefaults.connectionTimeout,
        heartbeatInterval: safeDefaults.heartbeatInterval,
        pongTimeout: safeDefaults.pongTimeout,
        maxMissedPongs: safeDefaults.maxMissedPongs,
        reconnectDelay: safeDefaults.reconnectDelay,
        reconnectJitterRatio: safeDefaults.reconnectJitterRatio,
        maxReconnectDelay: safeDefaults.maxReconnectDelay,
        maxReconnectAttempts: 0,
        allowsCellularAccess: safeDefaults.allowsCellularAccess,
        sessionIdentifier: safeDefaults.sessionIdentifier,
        requestHeaders: safeDefaults.requestHeaders,
        eventDeliveryPolicy: safeDefaults.eventDeliveryPolicy,
        eventMetricsReporter: safeDefaults.eventMetricsReporter
    )
)

// RTT observability via the current source callback. Treat richer pong context
// payloads as future-candidate API until they are promoted in the stability
// contract.
await manager.setOnPongHandler { _, context in
    let totalSeconds = Double(context.roundTrip.components.seconds) +
        Double(context.roundTrip.components.attoseconds) / 1_000_000_000_000_000_000
    let millis = totalSeconds * 1_000
    FileHandle.standardOutput.write(
        Data("↔︎ pong attempt=\(context.attemptNumber) rtt=\(String(format: "%.1f", millis))ms\n".utf8)
    )
}

await manager.setOnErrorHandler { _, error in
    writeStandardError("⚠️  error: \(error)\n")
}

let task = await manager.connect(url: url)
private let shutdown = ChatShutdown()

print("Type messages and press Enter. Ctrl-D to disconnect.")

// Event processing stays on one task; terminal disconnects are reported
// back to the main flow so the sample can exit instead of hanging on stdin.
let eventTask = Task {
    for await event in await manager.events(for: task) {
        switch event {
        case .connected(let subprotocol):
            print("✓ connected subprotocol=\(subprotocol ?? "<none>")")
        case .disconnected(let error):
            await shutdown.finish(.remoteDisconnect(error))
            return
        case .message(let data):
            print("← \(data.count) bytes")
        case .string(let text):
            print("← \(text)")
        case .ping(let context):
            print("→ ping attempt=\(context.attemptNumber)")
        case .pong:
            // RTT logging lives in `setOnPongHandler(_:)` above; keep the
            // event-stream branch non-binding to show payload-agnostic matching.
            break
        case .error(let wsError):
            print("⚠︎ event-stream error: \(wsError)")
            if await task.state == .failed {
                await shutdown.finish(.terminalFailure(wsError))
                return
            }
        @unknown default:
            break
        }
    }

    await shutdown.finish(.eventStreamEnded)
}

// Read stdin asynchronously so the main flow can still terminate on remote
// disconnects or terminal failures while input is idle.
let stdinTask = Task {
    var pendingLine = Data()

    do {
        for try await byte in FileHandle.standardInput.bytes {
            switch byte {
            case 0x0A:
                guard let line = String(data: pendingLine, encoding: .utf8) else {
                    await shutdown.finish(.stdinFailure("stdin contained non-UTF8 data"))
                    return
                }
                do {
                    try await manager.send(task, string: line)
                } catch {
                    await shutdown.finish(.sendFailure(String(describing: error)))
                    return
                }
                print("→ \(line)")
                pendingLine.removeAll(keepingCapacity: true)
            case 0x0D:
                continue
            default:
                pendingLine.append(contentsOf: [byte])
            }
        }

        if !pendingLine.isEmpty {
            guard let line = String(data: pendingLine, encoding: .utf8) else {
                await shutdown.finish(.stdinFailure("stdin contained non-UTF8 data"))
                return
            }
            do {
                try await manager.send(task, string: line)
            } catch {
                await shutdown.finish(.sendFailure(String(describing: error)))
                return
            }
            print("→ \(line)")
        }

        await shutdown.finish(.userEOF)
    } catch is CancellationError {
        return
    } catch {
        await shutdown.finish(.stdinFailure(String(describing: error)))
    }
}

private let termination = await shutdown.wait()
eventTask.cancel()
stdinTask.cancel()

switch termination {
case .userEOF:
    await manager.disconnect(task, closeCode: .normalClosure)
    exit(0)
case .remoteDisconnect(let error):
    if let error {
        print("✗ disconnected: \(error)")
    } else {
        print("✗ disconnected")
    }
    exit(1)
case .terminalFailure(let error):
    writeStandardError("✗ terminal failure: \(error)\n")
    exit(1)
case .sendFailure(let message):
    writeStandardError("⚠︎ send failed: \(message)\n")
    await manager.disconnect(task, closeCode: .normalClosure)
    exit(1)
case .stdinFailure(let message):
    writeStandardError("⚠︎ stdin error: \(message)\n")
    await manager.disconnect(task, closeCode: .normalClosure)
    exit(1)
case .eventStreamEnded:
    writeStandardError("✗ event stream closed unexpectedly\n")
    exit(1)
}
