import Foundation
import os

@testable import InnoNetwork
@testable import InnoNetworkDownload

/// Scripted `URLProtocol` for end-to-end download tests that must exercise a
/// real `URLSessionDownloadTask` (HTTP status on `task.response`, Foundation's
/// own resume-data generation) without touching the network.
///
/// Scripts are keyed by request host so suites running in parallel never
/// observe each other's steps. Each `startLoading()` consumes the next step
/// for its host and records the request that reached the transport.
final class ScriptedDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    struct Step: Sendable {
        var statusCode: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// When set, the load fails with this error after `body` is delivered.
        var failure: URLError.Code?
        /// Holds `failure` back until the gate opens. Foundation writes
        /// received bytes to its temporary file asynchronously, so a test
        /// that needs resume data with a known non-zero offset opens the
        /// gate once the session has reported those bytes as written.
        var failureGate: ScriptedGate?
    }

    /// Produces the step for one transport request. The second argument is
    /// the zero-based index of the request for its host.
    typealias Responder = @Sendable (URLRequest, Int) -> Step?

    private struct Script {
        var responder: Responder
        var requests: [URLRequest] = []
    }

    private static let scripts = OSAllocatedUnfairLock<[String: Script]>(initialState: [:])

    static func register(host: String, responder: @escaping Responder) {
        scripts.withLock { $0[host] = Script(responder: responder) }
    }

    static func register(host: String, steps: [Step]) {
        register(host: host) { _, index in
            steps.indices.contains(index) ? steps[index] : nil
        }
    }

    static func unregister(host: String) {
        scripts.withLock { _ = $0.removeValue(forKey: host) }
    }

    /// Requests that reached the transport for `host`, in arrival order.
    static func requests(forHost host: String) -> [URLRequest] {
        scripts.withLock { $0[host]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return scripts.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = self.request
        let scripted = Self.scripts.withLock { scripts -> (Responder, Int)? in
            guard let host = request.url?.host, var script = scripts[host] else { return nil }
            let index = script.requests.count
            script.requests.append(request)
            scripts[host] = script
            return (script.responder, index)
        }
        let step = scripted.flatMap { responder, index in responder(request, index) }
        guard let step, let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: step.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: step.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !step.body.isEmpty {
            client?.urlProtocol(self, didLoad: step.body)
        }
        guard let failure = step.failure else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let gate = step.failureGate else {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        Task {
            // Upper bound only: a test that never opens the gate still ends.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(20))
                gate.open()
            }
            await gate.wait()
            timeout.cancel()
            self.client?.urlProtocol(self, didFailWithError: URLError(failure))
        }
    }

    override func stopLoading() {}
}


/// One-shot latch a test opens to release a scripted transport failure.
final class ScriptedGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state -> Bool in
                guard !state.isOpen else { return true }
                state.waiters.append(continuation)
                return false
            }
            if isOpen {
                continuation.resume()
            }
        }
    }
}


/// Wires a `DownloadManager` to a real foreground `URLSession` whose loads
/// are served by ``ScriptedDownloadURLProtocol``. The production
/// `DownloadSessionDelegate` is the session delegate, so the full
/// delegate → channel → manager pipeline runs exactly as it does in an app.
final class ScriptedDownloadContext: Sendable {
    let manager: DownloadManager
    let store: InMemoryDownloadTaskStore
    let host: String
    let rootURL: URL
    let destinationURL: URL

    convenience init(
        label: String,
        steps: [ScriptedDownloadURLProtocol.Step],
        maxRetryCount: Int = 2,
        retryDelay: TimeInterval = 0,
        acceptableStatusCodes: Set<Int> = DownloadHTTPStatusFailure.defaultAcceptableStatusCodes
    ) throws {
        try self.init(
            label: label,
            maxRetryCount: maxRetryCount,
            retryDelay: retryDelay,
            acceptableStatusCodes: acceptableStatusCodes
        ) { _, index in
            steps.indices.contains(index) ? steps[index] : nil
        }
    }

    init(
        label: String,
        maxRetryCount: Int = 2,
        retryDelay: TimeInterval = 0,
        acceptableStatusCodes: Set<Int> = DownloadHTTPStatusFailure.defaultAcceptableStatusCodes,
        responder: @escaping ScriptedDownloadURLProtocol.Responder
    ) throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "inno-scripted-download-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        self.destinationURL = rootURL.appendingPathComponent("payload.bin", isDirectory: false)

        let host = "\(UUID().uuidString.lowercased()).scripted-download.invalid"
        self.host = host
        ScriptedDownloadURLProtocol.register(host: host, responder: responder)

        let configuration = DownloadConfiguration(
            maxRetryCount: maxRetryCount,
            maxTotalRetries: maxRetryCount,
            retryDelay: retryDelay,
            acceptableStatusCodes: acceptableStatusCodes,
            sessionIdentifier: makeDownloadTestSessionIdentifier(label),
            networkMonitor: nil,
            waitsForNetworkChanges: false,
            persistenceBaseDirectoryURL: rootURL
        )
        let store = InMemoryDownloadTaskStore()
        self.store = store
        let callbacks = DownloadSessionDelegateCallbacks()
        let backgroundCompletionStore = BackgroundCompletionStore()
        let completionStager = DownloadCompletionStager(
            directoryURL: DownloadCompletionStager.directoryURL(for: configuration)
        )
        let delegate = Self.makeDelegate(
            configuration: configuration,
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore,
            completionStager: completionStager
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ScriptedDownloadURLProtocol.self]
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.manager = try DownloadManager(
            configuration: configuration,
            persistence: DownloadTaskPersistence(store: store),
            urlSession: session,
            delegate: delegate,
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore,
            completionStager: completionStager
        )
    }

    private static func makeDelegate(
        configuration: DownloadConfiguration,
        callbacks: DownloadSessionDelegateCallbacks,
        backgroundCompletionStore: BackgroundCompletionStore,
        completionStager: DownloadCompletionStager
    ) -> DownloadSessionDelegate {
        DownloadSessionDelegate(
            callbacks: callbacks,
            backgroundCompletionStore: backgroundCompletionStore,
            completionStager: completionStager,
            completionAdmissionGate: DownloadCompletionAdmissionGate(),
            allowsInsecureHTTP: configuration.allowsInsecureHTTP,
            acceptableStatusCodes: configuration.acceptableStatusCodes
        )
    }

    var sourceURL: URL {
        URL(string: "https://\(host)/files/payload.bin")!
    }

    var transportRequests: [URLRequest] {
        ScriptedDownloadURLProtocol.requests(forHost: host)
    }

    func startDownload() async -> DownloadTask {
        await manager.download(url: sourceURL, to: destinationURL)
    }

    func tearDown() async {
        await manager.shutdown()
        ScriptedDownloadURLProtocol.unregister(host: host)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
