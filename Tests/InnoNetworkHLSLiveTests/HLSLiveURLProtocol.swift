import Foundation

final class HLSLiveURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
        let delay: TimeInterval

        init(
            statusCode: Int,
            data: Data,
            headers: [String: String],
            delay: TimeInterval = 0
        ) {
            self.statusCode = statusCode
            self.data = data
            self.headers = headers
            self.delay = max(0, delay)
        }
    }

    nonisolated(unsafe) private static var responses: [String: [Response]] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func register(
        _ response: Response,
        for url: URL
    ) {
        lock.lock()
        responses[url.absoluteString, default: []].append(response)
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        responses.removeAll()
        requests.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        Self.lock.lock()
        Self.requests.append(request)
        var queue = Self.responses[url.absoluteString] ?? []
        let response = queue.first
        if !queue.isEmpty {
            queue.removeFirst()
            Self.responses[url.absoluteString] = queue
        }
        Self.lock.unlock()

        guard
            let response,
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        if response.delay > 0 {
            Thread.sleep(forTimeInterval: response.delay)
        }
        client?.urlProtocol(
            self,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
