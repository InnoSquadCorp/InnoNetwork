import Foundation
import InnoNetwork

package struct WebSocketReceiveLoop {
    let runtimeRegistry: WebSocketRuntimeRegistry
    let eventHub: TaskEventHub<WebSocketEvent>

    package init(
        runtimeRegistry: WebSocketRuntimeRegistry,
        eventHub: TaskEventHub<WebSocketEvent>
    ) {
        self.runtimeRegistry = runtimeRegistry
        self.eventHub = eventHub
    }

    package func start(
        task: WebSocketTask,
        urlTask: any WebSocketURLTask,
        onError: @escaping @Sendable (Int, Error) -> Void
    ) async {
        await runtimeRegistry.createMessageListenerTask(for: task.id) {
            do {
                while true {
                    try Task.checkCancellation()
                    // Backpressure is deliberate here: the loop issues the
                    // next `receive()` only after the current message has
                    // run through callbacks and the bounded TaskEventHub
                    // publication path. There is no separate unbounded
                    // receive-side message buffer in this loop.
                    let message = try await urlTask.receive()

                    switch message {
                    case .string(let string):
                        await runtimeRegistry.onString?(task, string)
                        await eventHub.publish(.string(string), for: task.id)
                    case .data(let data):
                        await runtimeRegistry.onMessage?(task, data)
                        await eventHub.publish(.message(data), for: task.id)
                    @unknown default:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                onError(urlTask.taskIdentifier, error)
            }
        }
    }
}
