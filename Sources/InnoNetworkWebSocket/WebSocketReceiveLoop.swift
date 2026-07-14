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
        onEvent: (@Sendable (WebSocketEvent) async -> Void)? = nil,
        onError: @escaping @Sendable (Int, Error) -> Void
    ) async {
        await runtimeRegistry.createMessageListenerTask(for: task.id) {
            do {
                while true {
                    try Task.checkCancellation()
                    // Backpressure is deliberate here: the loop issues the
                    // next `receive()` only after the current message has
                    // run through the bounded TaskEventHub and callback
                    // fan-out path. There is no separate unbounded
                    // receive-side message buffer in this loop.
                    let message = try await urlTask.receive()
                    try Task.checkCancellation()

                    switch message {
                    case .string(let string):
                        let event = WebSocketEvent.string(string)
                        if let onEvent {
                            await onEvent(event)
                        } else {
                            let prepared = await runtimeRegistry.prepareStringEventFromCurrentWorker(
                                task,
                                string: string
                            )
                            guard prepared.isCurrentWorker else { return }
                            await eventHub.publish(event, for: task.id)
                            await runtimeRegistry.invokePreparedUserCallback(prepared.callback)
                        }
                    case .data(let data):
                        let event = WebSocketEvent.message(data)
                        if let onEvent {
                            await onEvent(event)
                        } else {
                            let prepared = await runtimeRegistry.prepareMessageEventFromCurrentWorker(
                                task,
                                data: data
                            )
                            guard prepared.isCurrentWorker else { return }
                            await eventHub.publish(event, for: task.id)
                            await runtimeRegistry.invokePreparedUserCallback(prepared.callback)
                        }
                    @unknown default:
                        break
                    }
                    try Task.checkCancellation()
                }
            } catch is CancellationError {
                return
            } catch {
                onError(urlTask.taskIdentifier, error)
            }
        }
    }
}
