import Foundation

package struct WebSocketPreparedConnection: Sendable {
    package let generation: Int
    package let request: URLRequest
}

package struct WebSocketConnectionCoordinator {
    let configuration: WebSocketConfiguration
    let runtimeRegistry: WebSocketRuntimeRegistry
    let isTransportAdmissionOpen: @Sendable () -> Bool

    package init(
        configuration: WebSocketConfiguration,
        runtimeRegistry: WebSocketRuntimeRegistry,
        isTransportAdmissionOpen: @escaping @Sendable () -> Bool
    ) {
        self.configuration = configuration
        self.runtimeRegistry = runtimeRegistry
        self.isTransportAdmissionOpen = isTransportAdmissionOpen
    }

    package func prepareConnection(_ task: WebSocketTask) async -> WebSocketPreparedConnection? {
        let generation = await task.connectionGeneration

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

        guard isTransportAdmissionOpen(), await task.isConnecting(generation: generation) else { return nil }
        for adapter in configuration.handshakeRequestAdapters {
            let requestToAdapt = request
            request = await runtimeRegistry.invokeUserCallback {
                await adapter.adapt(requestToAdapt)
            }
            guard isTransportAdmissionOpen(), await task.isConnecting(generation: generation) else { return nil }
        }

        return WebSocketPreparedConnection(generation: generation, request: request)
    }

    private static func request(_ request: URLRequest, containsHeaderNamed name: String) -> Bool {
        request.allHTTPHeaderFields?.keys.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) ?? false
    }
}
