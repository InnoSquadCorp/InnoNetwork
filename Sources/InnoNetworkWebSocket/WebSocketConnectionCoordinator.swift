import Foundation

package struct WebSocketConnectionCoordinator {
    let configuration: WebSocketConfiguration
    let session: any WebSocketURLSession
    let runtimeRegistry: WebSocketRuntimeRegistry
    let receiveLoop: WebSocketReceiveLoop

    package init(
        configuration: WebSocketConfiguration,
        session: any WebSocketURLSession,
        runtimeRegistry: WebSocketRuntimeRegistry,
        receiveLoop: WebSocketReceiveLoop
    ) {
        self.configuration = configuration
        self.session = session
        self.runtimeRegistry = runtimeRegistry
        self.receiveLoop = receiveLoop
    }

    package func startConnection(
        _ task: WebSocketTask,
        onReceiveError: @escaping @Sendable (Int, Error) -> Void
    ) async {
        let generation = await task.connectionGeneration
        await runtimeRegistry.cancelHeartbeatTask(for: task.id)

        var request = URLRequest(url: task.url)
        request.timeoutInterval = configuration.connectionTimeout

        for (key, value) in configuration.requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let subprotocols = task.subprotocols, !subprotocols.isEmpty {
            let protocolHeader = "Sec-WebSocket-Protocol"
            if !Self.request(request, containsHeaderNamed: protocolHeader) {
                request.setValue(subprotocols.joined(separator: ", "), forHTTPHeaderField: protocolHeader)
            }
        }

        for adapter in configuration.handshakeRequestAdapters {
            request = await adapter.adapt(request)
        }

        let urlTask = session.makeWebSocketTask(with: request)
        await runtimeRegistry.setMapping(
            webSocketTask: task,
            for: urlTask.taskIdentifier,
            generation: generation
        )
        await runtimeRegistry.setURLTask(urlTask, for: task.id)

        urlTask.resume()
        await receiveLoop.start(task: task, urlTask: urlTask, onError: onReceiveError)
    }

    private static func request(_ request: URLRequest, containsHeaderNamed name: String) -> Bool {
        request.allHTTPHeaderFields?.keys.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) ?? false
    }
}
