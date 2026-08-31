import Foundation

final class HLSPresentationTestURLProtocol: URLProtocol,
    @unchecked Sendable
{
    struct Response: Sendable {
        let data: Data
        let delay: TimeInterval
    }

    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var activeRequestCount = 0
    nonisolated(unsafe) private static var maximumActiveRequestCountStorage = 0
    private static let lock = NSLock()

    private let lifecycleLock = NSLock()
    private var isActive = false

    static func register(
        _ data: Data,
        for url: URL,
        delay: TimeInterval = 0
    ) {
        lock.withLock {
            responses[url.absoluteString] = Response(
                data: data,
                delay: delay
            )
        }
    }

    static func capturedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    static func maximumActiveRequestCount() -> Int {
        lock.withLock { maximumActiveRequestCountStorage }
    }

    static func reset() {
        lock.withLock {
            responses.removeAll()
            requests.removeAll()
            activeRequestCount = 0
            maximumActiveRequestCountStorage = 0
        }
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
            fail(with: .badURL)
            return
        }
        let response = Self.lock.withLock {
            Self.requests.append(request)
            return Self.responses[url.absoluteString]
        }
        guard let response else {
            fail(with: .resourceUnavailable)
            return
        }
        markActive()
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(
                deadline: .now() + response.delay
            ) { [weak self] in
                self?.deliver(response, for: url)
            }
        } else {
            deliver(response, for: url)
        }
    }

    override func stopLoading() {
        markFinished()
    }

    private func deliver(
        _ response: Response,
        for url: URL
    ) {
        guard isRequestActive() else {
            return
        }
        guard
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/vnd.apple.mpegurl"
                ]
            )
        else {
            fail(with: .badServerResponse)
            return
        }
        client?.urlProtocol(
            self,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
        markFinished()
    }

    private func fail(with code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
        markFinished()
    }

    private func markActive() {
        lifecycleLock.withLock {
            isActive = true
        }
        Self.lock.withLock {
            Self.activeRequestCount += 1
            Self.maximumActiveRequestCountStorage = max(
                Self.maximumActiveRequestCountStorage,
                Self.activeRequestCount
            )
        }
    }

    private func isRequestActive() -> Bool {
        lifecycleLock.withLock { isActive }
    }

    private func markFinished() {
        let wasActive = lifecycleLock.withLock {
            let value = isActive
            isActive = false
            return value
        }
        guard wasActive else {
            return
        }
        Self.lock.withLock {
            Self.activeRequestCount = max(
                0,
                Self.activeRequestCount - 1
            )
        }
    }
}
