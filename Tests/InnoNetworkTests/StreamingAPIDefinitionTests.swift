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

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw error
    }
}


private final class DelayedFailingBytesSession: URLSessionProtocol, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.badServerResponse)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await Task.sleep(for: .milliseconds(200))
        throw URLError(.badServerResponse)
    }
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
            guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
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
}
