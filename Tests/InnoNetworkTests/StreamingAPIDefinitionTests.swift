import Foundation
import Testing

@testable import InnoNetwork

private struct LineCounterStream: StreamingAPIDefinition {
    typealias Output = String

    var method: HTTPMethod { .get }
    var path: String { "/events" }

    func decode(line: String) throws -> String? {
        guard !line.isEmpty else { return nil }
        return line
    }
}


private final class ThrowingBytesSession: URLSessionProtocol, Sendable {
    let error: URLError

    init(error: URLError) {
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        throw error
    }
}


private final class DelayedFailingBytesSession: URLSessionProtocol, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.badServerResponse)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        try await Task.sleep(for: .milliseconds(200))
        throw URLError(.badServerResponse)
    }
}


/// URLProtocol that delivers a scripted sequence of clean responses for the
/// same URL. Used by resume-policy tests that only need handshake success/failure.
private final class SequencedStreamingURLProtocol: URLProtocol {
    enum Step: Sendable {
        case success(statusCode: Int, data: Data)
    }

    nonisolated(unsafe) private static var queue: [String: [Step]] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func enqueue(url: URL, steps: [Step]) {
        lock.lock()
        defer { lock.unlock() }
        queue[url.absoluteString] = steps
        captured[url.absoluteString] = []
    }

    static func capturedRequests(for url: URL) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured[url.absoluteString] ?? []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queue.removeAll()
        captured.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.captured[url.absoluteString, default: []].append(request)
        let next: Step?
        if var steps = Self.queue[url.absoluteString], !steps.isEmpty {
            next = steps.removeFirst()
            Self.queue[url.absoluteString] = steps
        } else {
            next = nil
        }
        Self.lock.unlock()

        switch next {
        case .success(let code, let data):
            guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }
}


/// Decoded "event" used by the resume tests. Each line is `id|payload`.
private struct ResumableEvent: Sendable, Equatable {
    let id: String
    let payload: String
}


/// Streaming definition that parses the lightweight `id|payload` line format.
private struct ResumableStream: StreamingAPIDefinition {
    typealias Output = ResumableEvent

    var method: HTTPMethod { .get }
    var path: String { "/sse" }
    var resumePolicy: StreamingResumePolicy

    init(resumePolicy: StreamingResumePolicy = .disabled) {
        self.resumePolicy = resumePolicy
    }

    func decode(line: String) throws -> ResumableEvent? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return ResumableEvent(id: String(parts[0]), payload: String(parts[1]))
    }

    func eventID(from output: ResumableEvent) -> String? {
        output.id
    }
}


private struct ResumableDecodeError: LocalizedError {
    let line: String

    var errorDescription: String? {
        "Malformed resumable stream line: \(line)"
    }
}


private struct ThrowingResumableStream: StreamingAPIDefinition {
    typealias Output = ResumableEvent

    var method: HTTPMethod { .get }
    var path: String { "/sse" }
    var resumePolicy: StreamingResumePolicy { .lastEventID(maxAttempts: 2, retryDelay: 0) }

    func decode(line: String) throws -> ResumableEvent? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ResumableDecodeError(line: line) }
        return ResumableEvent(id: String(parts[0]), payload: String(parts[1]))
    }

    func eventID(from output: ResumableEvent) -> String? {
        output.id
    }
}


private func makeSequencedStreamingURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SequencedStreamingURLProtocol.self]
    return URLSession(configuration: configuration)
}


private final class StreamingURLProtocol: URLProtocol {
    enum ResponseSpec {
        case success(statusCode: Int, data: Data)
        case failure(Error)
    }

    nonisolated(unsafe) private static var responses: [String: ResponseSpec] = [:]
    private static let lock = NSLock()

    static func register(url: URL, response: ResponseSpec) {
        lock.lock()
        responses[url.absoluteString] = response
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch Self.dequeue(url: url) {
        case .success(let statusCode, let data):
            guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}

    private static func dequeue(url: URL) -> ResponseSpec? {
        lock.lock()
        let response = responses.removeValue(forKey: url.absoluteString)
        lock.unlock()
        return response
    }
}


private actor StreamingEventStore {
    private var events: [NetworkEvent] = []

    func append(_ event: NetworkEvent) {
        events.append(event)
    }

    func snapshot() -> [NetworkEvent] {
        events
    }
}


private struct StreamingEventObserver: NetworkEventObserving {
    let store: StreamingEventStore

    func handle(_ event: NetworkEvent) async {
        await store.append(event)
    }
}


private struct StreamingStatusRewritingInterceptor: ResponseInterceptor {
    let statusCode: Int

    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        guard let httpResponse = urlResponse.response else {
            throw NetworkError.invalidRequestConfiguration("Missing HTTPURLResponse for stream response rewrite.")
        }
        return Response(
            statusCode: statusCode,
            data: urlResponse.data,
            request: urlResponse.request,
            response: httpResponse
        )
    }
}


private func makeStreamingURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingURLProtocol.self]
    return URLSession(configuration: configuration)
}


private func uniqueStreamingBaseURL() -> URL {
    URL(string: "https://stream-\(UUID().uuidString).example.com/v1")!
}


private func waitForStreamingEvents(
    store: StreamingEventStore,
    minimumCount: Int,
    timeout: TimeInterval = 1.0
) async -> [NetworkEvent] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let events = await store.snapshot()
        if events.count >= minimumCount {
            return events
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await store.snapshot()
}


private func streamingEventName(_ event: NetworkEvent) -> String {
    switch event {
    case .requestStart:
        return "start"
    case .requestAdapted:
        return "adapted"
    case .responseReceived:
        return "response"
    case .retryScheduled:
        return "retry"
    case .requestFinished:
        return "finished"
    case .requestFailed:
        return "failed"
    }
}


@Suite("Streaming API Definition Tests")
struct StreamingAPIDefinitionTests {

    @Test("stream() throws when the URL session does not implement bytes()")
    func streamUnsupportedTransportThrows() async throws {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: NetworkError.self) {
            _ = try await iterator.next()
        }
    }

    @Test("stream() decode(line:) returning nil filters lines")
    func decodeNilFiltersLines() throws {
        let definition = LineCounterStream()

        // Empty line → nil (filtered)
        #expect(try definition.decode(line: "") == nil)
        // Non-empty → echoed
        #expect(try definition.decode(line: "data: ping") == "data: ping")
    }

    @Test("stream() emits the request lifecycle events")
    func streamEmitsLifecycleEvents() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 200, data: Data("one\ntwo\n".utf8))
        )
        let store = StreamingEventStore()
        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            eventObservers: [StreamingEventObserver(store: store)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: makeStreamingURLSession())

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        #expect(values == ["one", "two"])
        let events = await waitForStreamingEvents(store: store, minimumCount: 4)
        #expect(events.map(streamingEventName) == ["start", "adapted", "response", "finished"])
        let finishedByteCounts = events.compactMap { event -> Int? in
            if case .requestFinished(_, _, let byteCount) = event { return byteCount }
            return nil
        }
        #expect(finishedByteCounts == ["one".utf8.count + "two".utf8.count])
    }

    @Test("stream() response interceptor status rewrite controls validation")
    func streamResponseInterceptorStatusRewriteControlsValidation() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 500, data: Data("accepted\n".utf8))
        )
        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            responseInterceptors: [StreamingStatusRewritingInterceptor(statusCode: 200)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: makeStreamingURLSession())

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        #expect(values == ["accepted"])
    }

    @Test("stream() applies current token from RefreshTokenPolicy")
    func streamAppliesCurrentRefreshTokenPolicyToken() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("authorized\n".utf8))
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { "stream-token" },
                    refreshToken: { "unused" }
                )
            ),
            session: makeSequencedStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(values == ["authorized"])
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Authorization") == "Bearer stream-token")
    }

    @Test("stream() maps URLError.timedOut to NetworkError.timeout(.requestTimeout)")
    func streamMapsTimedOutToRequestTimeout() async throws {
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: ThrowingBytesSession(error: URLError(.timedOut))
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream timeout error")
        } catch let error as NetworkError {
            switch error {
            case .timeout(.requestTimeout, let underlying):
                #expect(underlying?.domain == NSURLErrorDomain)
                #expect(underlying?.code == URLError.Code.timedOut.rawValue)
            default:
                Issue.record("Expected NetworkError.timeout(.requestTimeout), got \(error)")
            }
        }
    }

    @Test("stream() maps URLError.cannotConnectToHost to NetworkError.timeout(.connectionTimeout)")
    func streamMapsCannotConnectToConnectionTimeout() async throws {
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: ThrowingBytesSession(error: URLError(.cannotConnectToHost))
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream connection timeout error")
        } catch let error as NetworkError {
            switch error {
            case .timeout(.connectionTimeout, let underlying):
                #expect(underlying?.domain == NSURLErrorDomain)
                #expect(underlying?.code == URLError.Code.cannotConnectToHost.rawValue)
            default:
                Issue.record("Expected NetworkError.timeout(.connectionTimeout), got \(error)")
            }
        }
    }

    @Test("stream() registered immediately is cancelled by cancelAll")
    func streamCancelAllImmediatelyCancelsRegisteredTask() async throws {
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: DelayedFailingBytesSession()
        )

        let stream = client.stream(LineCounterStream())
        await client.cancelAll()

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream cancellation error")
        } catch let error as NetworkError {
            switch error {
            case .cancelled:
                break
            default:
                Issue.record("Expected NetworkError.cancelled, got \(error)")
            }
        }
    }

    // MARK: - Last-Event-ID resume policy

    // The end-to-end resume behavior (mid-stream disconnect, retry with
    // Last-Event-ID header) is exercised by the live-endpoint smoke tests
    // because URLSession.AsyncBytes buffers data deeply enough that
    // URLProtocol-driven partial delivery is unreliable in unit tests. The
    // checks below pin down the public surface and the policy accessors so a
    // future refactor cannot silently change the contract.

    @Test("StreamingResumePolicy default is .disabled")
    func resumePolicyDefaultsToDisabled() {
        let definition = LineCounterStream()
        switch definition.resumePolicy {
        case .disabled: break
        default: Issue.record("Expected default to be .disabled, got \(definition.resumePolicy)")
        }
    }

    @Test("ResumableStream exposes id via eventID(from:)")
    func eventIDExtractedFromDecodedOutput() throws {
        let definition = ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2))
        let event = try definition.decode(line: "42|payload")
        #expect(event == ResumableEvent(id: "42", payload: "payload"))
        #expect(definition.eventID(from: event!) == "42")
    }

    @Test("StreamingResumePolicy.lastEventID exposes maxAttempts and retryDelay")
    func resumePolicyAccessorsRoundTrip() {
        let policy = StreamingResumePolicy.lastEventID(maxAttempts: 5, retryDelay: 2.5)
        #expect(policy.maxAttempts == 5)
        #expect(policy.retryDelay == 2.5)

        let disabled = StreamingResumePolicy.disabled
        #expect(disabled.maxAttempts == 0)
        #expect(disabled.retryDelay == 0)
    }

    @Test("StreamingResumePolicy clamps negative parameters")
    func resumePolicyClampsNegatives() {
        let policy = StreamingResumePolicy.lastEventID(maxAttempts: -3, retryDelay: -1)
        #expect(policy.maxAttempts == 0)
        #expect(policy.retryDelay == 0)
    }

    @Test("StreamingResumePolicy is Equatable")
    func resumePolicyEquatable() {
        #expect(
            StreamingResumePolicy.lastEventID(maxAttempts: 3, retryDelay: 1)
                == StreamingResumePolicy.lastEventID(maxAttempts: 3, retryDelay: 1)
        )
        #expect(StreamingResumePolicy.disabled == .disabled)
        #expect(
            StreamingResumePolicy.disabled
                != StreamingResumePolicy.lastEventID(maxAttempts: 1, retryDelay: 1)
        )
    }

    @Test("stream() success path with .lastEventID issues exactly one request and no Last-Event-ID header")
    func resumePolicySuccessPathDoesNotAttachHeader() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2, retryDelay: 0))
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("1|alpha\n2|beta\n".utf8))
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5),
            session: makeSequencedStreamingURLSession()
        )

        var collected: [ResumableEvent] = []
        for try await event in client.stream(definition) {
            collected.append(event)
        }

        #expect(
            collected == [
                ResumableEvent(id: "1", payload: "alpha"),
                ResumableEvent(id: "2", payload: "beta"),
            ])

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test("Streaming resume state does not reuse a stale Last-Event-ID after an attempt sees no new cursor")
    func resumePolicyRequiresCurrentAttemptCursor() async throws {
        var state = StreamingResumeState()

        state.beginAttempt()
        state.observe(eventID: "1")
        #expect(state.lastSeenEventID == "1")
        #expect(state.canResume(maxAttempts: 2, completedResumeAttempts: 0))

        state.beginAttempt()
        state.observe(eventID: nil)
        #expect(state.lastSeenEventID == "1")
        #expect(!state.canResume(maxAttempts: 2, completedResumeAttempts: 1))
    }

    @Test("stream() does not resume Last-Event-ID after decode errors")
    func resumePolicyDoesNotResumeAfterDecodeError() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ThrowingResumableStream()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("1|alpha\nmalformed\n".utf8)),
                .success(statusCode: 200, data: Data("2|beta\n".utf8)),
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5, captureFailurePayload: true),
            session: makeSequencedStreamingURLSession()
        )

        var collected: [ResumableEvent] = []
        do {
            for try await event in client.stream(definition) {
                collected.append(event)
            }
            Issue.record("Expected decode error to surface")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, nil):
                #expect(underlying.message.contains("Malformed resumable stream line"))
            default:
                Issue.record("Expected NetworkError.underlying decode error, got \(error)")
            }
        }

        #expect(collected == [ResumableEvent(id: "1", payload: "alpha")])
        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test("stream() handshake error does not trigger Last-Event-ID resume")
    func resumePolicyDoesNotResumeOnHandshakeError() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2, retryDelay: 0))
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                // 500 fails the acceptable-status guard before any bytes are
                // consumed. Resume is reserved for mid-stream transport faults,
                // not server-driven handshake decisions.
                .success(statusCode: 500, data: Data()),
                .success(statusCode: 200, data: Data("1|alpha\n".utf8)),
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5),
            session: makeSequencedStreamingURLSession()
        )

        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected handshake error to surface")
        } catch let error as NetworkError {
            switch error {
            case .statusCode(let response):
                #expect(response.statusCode == 500)
            default:
                Issue.record("Expected NetworkError.statusCode(500), got \(error)")
            }
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        // Exactly one request — no resume.
        #expect(captured.count == 1)
    }
}
