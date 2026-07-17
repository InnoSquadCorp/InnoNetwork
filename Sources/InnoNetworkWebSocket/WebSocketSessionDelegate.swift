import Foundation
import InnoNetwork
import os

package final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {
    private static let requiredHandshakeHeaderNames: Set<String> = [
        "connection",
        "upgrade",
        "sec-websocket-key",
        "sec-websocket-version",
        "sec-websocket-extensions",
        "sec-websocket-protocol",
    ]

    private let callbacks: WebSocketSessionDelegateCallbacks
    private let allowsInsecureWebSocket: Bool
    private let rejectedRedirectTaskIdentifiers = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
    private let redirectProtectedHeaderNames = OSAllocatedUnfairLock<[Int: Set<String>]>(initialState: [:])

    package init(
        callbacks: WebSocketSessionDelegateCallbacks,
        allowsInsecureWebSocket: Bool = false
    ) {
        self.callbacks = callbacks
        self.allowsInsecureWebSocket = allowsInsecureWebSocket
        super.init()
    }

    /// Captures header names from the caller-prepared request before CFNetwork
    /// injects its required WebSocket handshake fields. Using
    /// `URLSessionTask.originalRequest` here would accidentally classify fields
    /// such as `Sec-WebSocket-Key` as caller credentials and removing them would
    /// make the redirected handshake invalid.
    package func registerRedirectProtectedHeaderNames(
        _ names: some Sequence<String>,
        for taskIdentifier: Int
    ) {
        let normalizedNames = Set(names.map { $0.lowercased() })
            .subtracting(Self.requiredHandshakeHeaderNames)
        redirectProtectedHeaderNames.withLock { protectedNames in
            protectedNames[taskIdentifier] = normalizedNames
        }
    }

    package func removeRedirectProtectedHeaderNames(for taskIdentifier: Int) {
        _ = redirectProtectedHeaderNames.withLock { protectedNames in
            protectedNames.removeValue(forKey: taskIdentifier)
        }
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        guard let retainedSourceURL = task.currentRequest?.url ?? task.originalRequest?.url,
            let targetURL = newRequest.url
        else {
            rejectRedirect(task: task, completionHandler: completionHandler)
            return
        }
        let sourceURL = response.url ?? retainedSourceURL
        let originalURL = task.originalRequest?.url ?? retainedSourceURL
        guard
            let sourceWebSocketURL = Self.webSocketEquivalentURL(sourceURL),
            let originalWebSocketURL = Self.webSocketEquivalentURL(originalURL),
            let targetWebSocketURL = Self.webSocketEquivalentURL(targetURL)
        else {
            rejectRedirect(task: task, completionHandler: completionHandler)
            return
        }

        do {
            try NetworkURLAdmission.validate(
                targetWebSocketURL,
                policy: .webSocket(allowsInsecure: allowsInsecureWebSocket)
            )
        } catch {
            rejectRedirect(task: task, completionHandler: completionHandler)
            return
        }

        // A plain-WS opt-in permits a deliberately insecure starting URL; it
        // never permits a secure handshake to be downgraded during redirect.
        guard !Self.isSecureDowngrade(from: sourceWebSocketURL, to: targetWebSocketURL) else {
            rejectRedirect(task: task, completionHandler: completionHandler)
            return
        }

        var admittedRequest = newRequest
        if !Self.isSameOrigin(originalWebSocketURL, targetWebSocketURL) {
            // Bind the credential boundary to the first handshake request, not
            // the immediately preceding hop. Otherwise an A -> B -> B chain
            // could reintroduce credentials on its second redirect. Treat every
            // caller-provided original header as protected so adapters can use
            // arbitrary authentication names without maintaining a global list.
            // The names were captured before CFNetwork injected the WebSocket
            // upgrade fields, which must survive the redirect.
            let protectedHeaderNames = redirectProtectedHeaderNames.withLock {
                $0[task.taskIdentifier] ?? []
            }
            let headerNames = admittedRequest.allHTTPHeaderFields?.keys ?? [:].keys
            for name in Array(headerNames)
            where protectedHeaderNames.contains(name.lowercased())
                || DefaultRedirectPolicy.sensitiveHeaders.contains(name.lowercased())
            {
                admittedRequest.setValue(nil, forHTTPHeaderField: name)
            }
        }
        completionHandler(admittedRequest)
    }

    package func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        _ = session
        removeRedirectProtectedHeaderNames(for: webSocketTask.taskIdentifier)
        guard !isRejectedRedirectTask(webSocketTask.taskIdentifier) else { return }
        callbacks.handleConnected(
            taskIdentifier: webSocketTask.taskIdentifier,
            protocolName: protocolName
        )
    }

    package func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _ = session
        removeRedirectProtectedHeaderNames(for: webSocketTask.taskIdentifier)
        guard !isRejectedRedirectTask(webSocketTask.taskIdentifier) else { return }
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        // Convert Apple's close-code enum to the library's `WebSocketCloseCode`
        // at the Foundation boundary. All downstream code works with the
        // canonical type so retryable variants (1012/1013) and custom (3xxx/4xxx)
        // codes survive the trip without losing information.
        callbacks.handleDisconnected(
            taskIdentifier: webSocketTask.taskIdentifier,
            closeCode: WebSocketCloseCode(closeCode),
            reason: reasonString
        )
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        _ = session
        removeRedirectProtectedHeaderNames(for: task.taskIdentifier)
        if rejectedRedirectTaskIdentifiers.withLock({ $0.remove(task.taskIdentifier) != nil }) {
            return
        }
        guard let error = error else { return }
        callbacks.handleError(
            taskIdentifier: task.taskIdentifier,
            error: SendableUnderlyingError(error),
            statusCode: (task.response as? HTTPURLResponse)?.statusCode
        )
    }

    package func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        _ = session
        rejectedRedirectTaskIdentifiers.withLock { $0.removeAll(keepingCapacity: false) }
        redirectProtectedHeaderNames.withLock { $0.removeAll(keepingCapacity: false) }
        callbacks.handleInvalidation(error.map(SendableUnderlyingError.init))
    }

    private func rejectRedirect(
        task: URLSessionTask,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let shouldReport = rejectedRedirectTaskIdentifiers.withLock { identifiers in
            identifiers.insert(task.taskIdentifier).inserted
        }
        if shouldReport {
            callbacks.handleRedirectRejected(
                taskIdentifier: task.taskIdentifier,
                error: .invalidURL("Rejected by WebSocket redirect admission policy")
            )
        }
        completionHandler(nil)
        task.cancel()
    }

    private func isRejectedRedirectTask(_ taskIdentifier: Int) -> Bool {
        rejectedRedirectTaskIdentifiers.withLock { $0.contains(taskIdentifier) }
    }

    /// Foundation may surface handshake redirects with either WebSocket or
    /// HTTP spellings. Normalize only for admission and origin comparison;
    /// the request returned to Foundation keeps its proposed URL unchanged.
    private static func webSocketEquivalentURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "wss":
            components.scheme = "wss"
        case "ws":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            return nil
        }
        return components.url
    }

    private static func isSecureDowngrade(from sourceURL: URL, to targetURL: URL) -> Bool {
        sourceURL.scheme?.lowercased() == "wss" && targetURL.scheme?.lowercased() == "ws"
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
            lhs.host?.lowercased() == rhs.host?.lowercased()
        else { return false }
        return effectivePort(of: lhs) == effectivePort(of: rhs)
    }

    private static func effectivePort(of url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "wss" ? 443 : 80
    }
}


package final class WebSocketSessionDelegateCallbacks: Sendable {
    package typealias ConnectedHandler = @Sendable (Int, String?) -> Void
    package typealias DisconnectedHandler = @Sendable (Int, WebSocketCloseCode, String?) -> Void
    package typealias ErrorHandler = @Sendable (Int, SendableUnderlyingError, Int?) -> Void
    package typealias RedirectRejectedHandler = @Sendable (Int, WebSocketError) -> Void
    package typealias InvalidationHandler = @Sendable (SendableUnderlyingError?) -> Void

    private let connectedHandlerLock = OSAllocatedUnfairLock<ConnectedHandler?>(initialState: nil)
    private let disconnectedHandlerLock = OSAllocatedUnfairLock<DisconnectedHandler?>(initialState: nil)
    private let errorHandlerLock = OSAllocatedUnfairLock<ErrorHandler?>(initialState: nil)
    private let redirectRejectedHandlerLock = OSAllocatedUnfairLock<RedirectRejectedHandler?>(initialState: nil)
    private let invalidationHandlerLock = OSAllocatedUnfairLock<InvalidationHandler?>(initialState: nil)

    package init() {}

    package func setHandlers(
        onConnected: @escaping ConnectedHandler,
        onDisconnected: @escaping DisconnectedHandler,
        onError: @escaping ErrorHandler,
        onRedirectRejected: @escaping RedirectRejectedHandler = { _, _ in }
    ) {
        connectedHandlerLock.withLock { $0 = onConnected }
        disconnectedHandlerLock.withLock { $0 = onDisconnected }
        errorHandlerLock.withLock { $0 = onError }
        redirectRejectedHandlerLock.withLock { $0 = onRedirectRejected }
    }

    package func setInvalidationHandler(_ callback: @escaping InvalidationHandler) {
        invalidationHandlerLock.withLock { $0 = callback }
    }

    package func handleConnected(taskIdentifier: Int, protocolName: String?) {
        connectedHandlerLock.withLock { $0 }?(taskIdentifier, protocolName)
    }

    package func handleDisconnected(taskIdentifier: Int, closeCode: WebSocketCloseCode, reason: String?) {
        disconnectedHandlerLock.withLock { $0 }?(taskIdentifier, closeCode, reason)
    }

    package func handleError(taskIdentifier: Int, error: SendableUnderlyingError, statusCode: Int?) {
        errorHandlerLock.withLock { $0 }?(taskIdentifier, error, statusCode)
    }

    package func handleRedirectRejected(taskIdentifier: Int, error: WebSocketError) {
        redirectRejectedHandlerLock.withLock { $0 }?(taskIdentifier, error)
    }

    package func handleInvalidation(_ error: SendableUnderlyingError?) {
        invalidationHandlerLock.withLock { $0 }?(error)
    }
}
