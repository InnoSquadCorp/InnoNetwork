import Foundation
import InnoNetwork

package struct WebSocketPreparedConnection: Sendable {
    package let generation: Int
    package let request: URLRequest
}

package enum WebSocketConnectionPreparationOutcome: Sendable {
    case prepared(WebSocketPreparedConnection)
    case cancelled
    case failed(generation: Int, underlying: SendableUnderlyingError)
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

    package func prepareConnection(_ task: WebSocketTask) async -> WebSocketConnectionPreparationOutcome {
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

        guard isTransportAdmissionOpen(), await task.isConnecting(generation: generation) else {
            return .cancelled
        }
        for adapter in configuration.handshakeRequestAdapters {
            let requestToAdapt = request
            do {
                request = try await runtimeRegistry.invokeUserCallback {
                    try await adapter.adapt(requestToAdapt)
                }
            } catch {
                // Bind the error to the generation that entered adaptation.
                // If disconnect, shutdown, or another lifecycle transition won
                // while the user callback was suspended, discard the stale
                // failure instead of applying it to a newer task state.
                guard isTransportAdmissionOpen(), await task.isConnecting(generation: generation) else {
                    return .cancelled
                }
                return .failed(
                    generation: generation,
                    underlying: SendableUnderlyingError(error)
                )
            }
            guard isTransportAdmissionOpen(), await task.isConnecting(generation: generation) else {
                return .cancelled
            }
        }

        return .prepared(WebSocketPreparedConnection(generation: generation, request: request))
    }

    private static func request(_ request: URLRequest, containsHeaderNamed name: String) -> Bool {
        request.allHTTPHeaderFields?.keys.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) ?? false
    }
}
