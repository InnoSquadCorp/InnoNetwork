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
        urlTask: URLSessionWebSocketTask,
        onError: @escaping @Sendable (Int, Error) -> Void
    ) async {
        let listenerTask = Task {
            do {
                while true {
                    try Task.checkCancellation()
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

        await runtimeRegistry.setMessageListenerTask(listenerTask, for: task.id)
    }
}
