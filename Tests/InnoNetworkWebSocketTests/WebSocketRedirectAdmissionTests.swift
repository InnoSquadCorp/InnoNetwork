import Foundation
import Network
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

@Suite("WebSocket redirect admission", .serialized)
struct WebSocketRedirectAdmissionTests {
    @Test("Same-origin secure handshake redirect is admitted")
    func sameOriginSecureRedirectIsAdmitted() throws {
        let source = URL(string: "wss://socket.example.com/start")!
        let target = URL(string: "wss://socket.example.com/v2")!
        let context = makeRedirectDelegateContext()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: source)
        defer { session.invalidateAndCancel() }

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(source: source, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: context.decisions.record
        )

        guard case .follow(let request) = try #require(context.decisions.values.first) else {
            Issue.record("Expected the same-origin WSS redirect to be followed")
            return
        }
        #expect(request.url == target)
        #expect(context.errors.values.isEmpty)
    }

    @Test("Secure handshake downgrade is rejected even with plain-WS opt-in")
    func secureDowngradeIsAlwaysRejected() throws {
        let source = URL(string: "wss://socket.example.com/start")!
        let target = URL(string: "ws://socket.example.com/plain")!
        let context = makeRedirectDelegateContext(allowsInsecureWebSocket: true)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: source)
        defer { session.invalidateAndCancel() }

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(source: source, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: context.decisions.record
        )

        guard case .reject = try #require(context.decisions.values.first) else {
            Issue.record("Expected WSS-to-WS redirect rejection")
            return
        }
        #expect(context.errors.values == [.invalidURL("Rejected by WebSocket redirect admission policy")])
    }

    @Test("Encoded traversal is rejected once and cancelled completion is suppressed")
    func traversalRedirectIsRejectedOnce() throws {
        let source = URL(string: "wss://socket.example.com/start")!
        let target = URL(string: "wss://socket.example.com/%252e%252e/private")!
        let context = makeRedirectDelegateContext()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: source)
        defer { session.invalidateAndCancel() }

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(source: source, target: target),
            newRequest: URLRequest(url: target),
            completionHandler: context.decisions.record
        )
        context.delegate.urlSession(
            session,
            task: task,
            didCompleteWithError: URLError(.cancelled)
        )

        guard case .reject = try #require(context.decisions.values.first) else {
            Issue.record("Expected traversal redirect rejection")
            return
        }
        #expect(context.errors.values.count == 1)
    }

    @Test("Cross-origin redirects strip credential headers")
    func crossOriginRedirectStripsCredentialHeaders() throws {
        let source = URL(string: "wss://socket.example.com/start")!
        let target = URL(string: "wss://edge.example.net/socket")!
        let context = makeRedirectDelegateContext()
        let session = URLSession(configuration: .ephemeral)
        var originalRequest = URLRequest(url: source)
        originalRequest.setValue("Bearer original", forHTTPHeaderField: "Authorization")
        originalRequest.setValue("tenant-secret", forHTTPHeaderField: "X-Tenant-Secret")
        originalRequest.setValue("chat.v2", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: originalRequest)
        context.delegate.registerRedirectProtectedHeaderNames(
            originalRequest.allHTTPHeaderFields?.keys ?? [:].keys,
            for: task.taskIdentifier
        )
        defer { session.invalidateAndCancel() }

        var redirectedRequest = URLRequest(url: target)
        redirectedRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        redirectedRequest.setValue("session=secret", forHTTPHeaderField: "Cookie")
        redirectedRequest.setValue("secret", forHTTPHeaderField: "X-API-Key")
        redirectedRequest.setValue("tenant-secret", forHTTPHeaderField: "X-Tenant-Secret")
        redirectedRequest.setValue("trace", forHTTPHeaderField: "X-Trace-ID")
        redirectedRequest.setValue("chat.v2", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(source: source, target: target),
            newRequest: redirectedRequest,
            completionHandler: context.decisions.record
        )

        guard case .follow(let request) = try #require(context.decisions.values.first) else {
            Issue.record("Expected an admitted cross-origin redirect")
            return
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Tenant-Secret") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Trace-ID") == "trace")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "chat.v2")
    }

    @Test("Redirect credentials stay bound to the original handshake origin")
    func multiHopRedirectCannotReintroduceCredentials() throws {
        let original = URL(string: "wss://socket.example.com/start")!
        let firstTarget = URL(string: "wss://edge.example.net/first")!
        let secondTarget = URL(string: "wss://edge.example.net/second")!
        let context = makeRedirectDelegateContext()
        let session = URLSession(configuration: .ephemeral)
        var originalRequest = URLRequest(url: original)
        originalRequest.setValue("Bearer original", forHTTPHeaderField: "Authorization")
        originalRequest.setValue("tenant-secret", forHTTPHeaderField: "X-Tenant-Secret")
        let task = session.webSocketTask(with: originalRequest)
        context.delegate.registerRedirectProtectedHeaderNames(
            originalRequest.allHTTPHeaderFields?.keys ?? [:].keys,
            for: task.taskIdentifier
        )
        defer { session.invalidateAndCancel() }

        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(source: original, target: firstTarget),
            newRequest: URLRequest(url: firstTarget),
            completionHandler: context.decisions.record
        )

        var secondRequest = URLRequest(url: secondTarget)
        secondRequest.setValue("Bearer reintroduced", forHTTPHeaderField: "Authorization")
        secondRequest.setValue("tenant-secret", forHTTPHeaderField: "X-Tenant-Secret")
        context.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(source: firstTarget, target: secondTarget),
            newRequest: secondRequest,
            completionHandler: context.decisions.record
        )

        guard context.decisions.values.count == 2,
            case .follow(let admittedRequest) = context.decisions.values[1]
        else {
            Issue.record("Expected both secure redirects to be admitted")
            return
        }
        #expect(admittedRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(admittedRequest.value(forHTTPHeaderField: "X-Tenant-Secret") == nil)
    }

    @Test("Real redirect preserves CFNetwork handshake fields while stripping caller secrets")
    func realRedirectPreservesRequiredHandshakeFields() async throws {
        let server = try WebSocketRedirectLoopbackServer()
        defer { server.stop() }
        let configuration = WebSocketConfiguration.advanced(
            connection: WebSocketConnectionPack(
                allowsInsecureWebSocket: true,
                requestHeaders: [
                    "Authorization": "Bearer secret",
                    "X-Tenant-Secret": "tenant-secret",
                ]
            ),
            liveness: WebSocketLivenessPack(heartbeatInterval: 0),
            reconnect: WebSocketReconnectPack(maxAttempts: 0)
        )
        let manager = WebSocketManager(configuration: configuration)
        let task = await manager.connect(url: server.sourceURL, subprotocols: ["chat.v2"])

        let requests = await server.waitForRequests(count: 2)
        guard requests.count >= 2 else {
            Issue.record("Expected the redirected WebSocket handshake to reach the loopback server")
            await manager.shutdown()
            return
        }

        let original = requests[0]
        let redirected = requests[1]
        #expect(original.path == "/start")
        #expect(original.headers["authorization"] == "Bearer secret")
        #expect(original.headers["x-tenant-secret"] == "tenant-secret")
        #expect(redirected.path == "/target")
        #expect(redirected.headers["authorization"] == nil)
        #expect(redirected.headers["x-tenant-secret"] == nil)
        #expect(redirected.headers["upgrade"]?.lowercased() == "websocket")
        #expect(redirected.headers["sec-websocket-key"]?.isEmpty == false)
        #expect(redirected.headers["sec-websocket-version"] == "13")
        #expect(redirected.headers["sec-websocket-protocol"] == "chat.v2")
        #expect(await waitForWebSocketState(task) { $0 == .failed })
        await manager.shutdown()
    }

    @Test("Redirect rejection is terminal and never schedules reconnect")
    func redirectRejectionIsTerminal() async throws {
        let configuration = WebSocketConfiguration(
            heartbeatInterval: 0,
            reconnectDelay: 0,
            maxReconnectAttempts: 3,
        )
        let session = StubWebSocketURLSession()
        let callbacks = WebSocketSessionDelegateCallbacks()
        let delegate = WebSocketSessionDelegate(
            callbacks: callbacks,
        )
        let delegateSession = URLSession(configuration: .ephemeral)
        let source = URL(string: "wss://socket.example.com/start")!
        let rejectedTarget = URL(string: "wss://socket.example.com/%252e%252e/private")!
        let delegateTask = delegateSession.webSocketTask(with: source)
        let urlTask = StubWebSocketURLTask(taskIdentifier: delegateTask.taskIdentifier)
        session.enqueue(urlTask)
        defer { delegateSession.invalidateAndCancel() }
        let manager = WebSocketManager(
            configuration: configuration,
            urlSession: session,
            delegate: delegate,
            callbacks: callbacks
        )

        let task = await manager.connect(url: source)
        let identifier = try #require(
            await waitForWebSocketRuntimeTaskIdentifier(manager: manager, task: task)
        )
        #expect(identifier == delegateTask.taskIdentifier)
        delegate.urlSession(
            delegateSession,
            task: delegateTask,
            willPerformHTTPRedirection: redirectResponse(source: source, target: rejectedTarget),
            newRequest: URLRequest(url: rejectedTarget),
            completionHandler: { _ in }
        )
        delegate.urlSession(
            delegateSession,
            task: delegateTask,
            didCompleteWithError: URLError(.cancelled)
        )

        #expect(await waitForWebSocketState(task) { $0 == .failed })
        let rejection = WebSocketError.invalidURL("Rejected by WebSocket redirect admission policy")
        #expect(await task.error == rejection)
        #expect(await task.attemptedReconnectCount == 0)
        #expect(session.createdTasks.count == 1)

        async let shutdown: Void = manager.shutdown()
        #expect(await session.waitForInvalidation())
        callbacks.handleInvalidation(nil)
        await shutdown
    }
}


private final class WebSocketRedirectDecisionRecorder: Sendable {
    enum Decision: Sendable {
        case follow(URLRequest)
        case reject
    }

    private let lock = OSAllocatedUnfairLock<[Decision]>(initialState: [])

    var values: [Decision] { lock.withLock { $0 } }

    func record(_ request: URLRequest?) {
        lock.withLock { $0.append(request.map(Decision.follow) ?? .reject) }
    }
}


private final class WebSocketRedirectErrorRecorder: Sendable {
    private let lock = OSAllocatedUnfairLock<[WebSocketError]>(initialState: [])

    var values: [WebSocketError] { lock.withLock { $0 } }

    func record(_ taskIdentifier: Int, _ error: WebSocketError) {
        _ = taskIdentifier
        lock.withLock { $0.append(error) }
    }
}


private struct WebSocketRedirectDelegateContext {
    let delegate: WebSocketSessionDelegate
    let decisions: WebSocketRedirectDecisionRecorder
    let errors: WebSocketRedirectErrorRecorder
}


private func makeRedirectDelegateContext(
    allowsInsecureWebSocket: Bool = false
) -> WebSocketRedirectDelegateContext {
    let callbacks = WebSocketSessionDelegateCallbacks()
    let errors = WebSocketRedirectErrorRecorder()
    callbacks.setHandlers(
        onConnected: { _, _ in },
        onDisconnected: { _, _, _ in },
        onError: { _, _, _ in },
        onRedirectRejected: errors.record
    )
    let decisions = WebSocketRedirectDecisionRecorder()
    return WebSocketRedirectDelegateContext(
        delegate: WebSocketSessionDelegate(
            callbacks: callbacks,
            allowsInsecureWebSocket: allowsInsecureWebSocket
        ),
        decisions: decisions,
        errors: errors
    )
}


private func redirectResponse(source: URL, target: URL) -> HTTPURLResponse {
    HTTPURLResponse(
        url: source,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString]
    )!
}


private struct WebSocketLoopbackRequest: Sendable {
    let path: String
    let headers: [String: String]
}


/// A two-hop loopback server is necessary here because URLProtocol does not
/// expose the real CFNetwork WebSocket redirect request. The first origin uses
/// `127.0.0.1`, then redirects to `localhost` on the same listener so the
/// delegate must apply its cross-origin header policy to an actual handshake.
private final class WebSocketRedirectLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "innonetwork.websocket-redirect-loopback")
    private var requests: [WebSocketLoopbackRequest] = []
    private var portValue: UInt16 = 0

    var sourceURL: URL {
        URL(string: "ws://127.0.0.1:\(portValue)/start")!
    }

    private var redirectURL: URL {
        URL(string: "ws://localhost:\(portValue)/target")!
    }

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success,
            let port = listener.port
        else {
            throw URLError(.cannotConnectToHost)
        }
        portValue = port.rawValue
    }

    func stop() {
        listener.cancel()
    }

    func waitForRequests(count: Int) async -> [WebSocketLoopbackRequest] {
        for _ in 0..<300 {
            let snapshot = queue.sync { requests }
            if snapshot.count >= count {
                return snapshot
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return queue.sync { requests }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = accumulated
            if let data {
                accumulated.append(data)
            }
            if let request = Self.parseRequest(accumulated) {
                requests.append(request)
                respond(to: request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, accumulated: accumulated)
            }
        }
    }

    private func respond(to request: WebSocketLoopbackRequest, on connection: NWConnection) {
        let response: String
        if request.path == "/start" {
            response =
                "HTTP/1.1 302 Found\r\n"
                + "Location: \(redirectURL.absoluteString)\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: close\r\n"
                + "\r\n"
        } else {
            response =
                "HTTP/1.1 400 Bad Request\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: close\r\n"
                + "\r\n"
        }
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private static func parseRequest(_ data: Data) -> WebSocketLoopbackRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
            let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return WebSocketLoopbackRequest(path: String(requestParts[1]), headers: headers)
    }
}
