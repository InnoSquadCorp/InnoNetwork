import Foundation

final class HLSURLProtocol: URLProtocol, @unchecked Sendable {
    enum ResponseSpec: Sendable {
        case success(
            statusCode: Int,
            data: Data,
            headers: [String: String]
        )
        case unfinished(
            statusCode: Int,
            data: Data,
            headers: [String: String]
        )
        case failingResponse(
            statusCode: Int,
            data: Data,
            headers: [String: String],
            errorCode: URLError.Code
        )
        case delayedSuccess(
            statusCode: Int,
            data: Data,
            headers: [String: String],
            delay: TimeInterval
        )
        case redirect(statusCode: Int, location: URL)
    }

    nonisolated(unsafe) private static var responses: [String: [ResponseSpec]] = [:]
    nonisolated(unsafe) private static var capturedRequestsStorage: [URLRequest] = []
    nonisolated(unsafe) private static var onStartLoading: (@Sendable (URL) -> Void)?
    nonisolated(unsafe) private static var onStopLoading: (@Sendable (URL) -> Void)?
    nonisolated(unsafe) private static var activeRequestCount = 0
    nonisolated(unsafe) private static var maximumActiveRequestCountStorage = 0
    private static let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var isActive = false

    static func register(
        _ response: ResponseSpec,
        for url: URL
    ) {
        lock.lock()
        responses[url.absoluteString, default: []].append(response)
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return capturedRequestsStorage
    }

    static func maximumActiveRequestCount() -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return maximumActiveRequestCountStorage
    }

    static func setStopLoadingHandler(
        _ handler: (@Sendable (URL) -> Void)?
    ) {
        lock.lock()
        onStopLoading = handler
        lock.unlock()
    }

    static func setStartLoadingHandler(
        _ handler: (@Sendable (URL) -> Void)?
    ) {
        lock.lock()
        onStartLoading = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responses.removeAll()
        capturedRequestsStorage.removeAll()
        onStartLoading = nil
        onStopLoading = nil
        activeRequestCount = 0
        maximumActiveRequestCountStorage = 0
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
        Self.capturedRequestsStorage.append(request)
        var queuedResponses =
            Self.responses[url.absoluteString] ?? []
        let responseSpec = queuedResponses.first
        if queuedResponses.count > 1 {
            queuedResponses.removeFirst()
            Self.responses[url.absoluteString] = queuedResponses
        }
        let startLoadingHandler = Self.onStartLoading
        Self.lock.unlock()
        markActive()
        startLoadingHandler?(url)

        switch responseSpec {
        case .success(let statusCode, let data, let headers):
            deliver(
                statusCode: statusCode,
                data: data,
                headers: headers,
                finishesLoading: true
            )
        case .unfinished(let statusCode, let data, let headers):
            deliver(
                statusCode: statusCode,
                data: data,
                headers: headers,
                finishesLoading: false
            )
        case .failingResponse(
            let statusCode,
            let data,
            let headers,
            let errorCode
        ):
            deliver(
                statusCode: statusCode,
                data: data,
                headers: headers,
                finishesLoading: false
            )
            client?.urlProtocol(
                self,
                didFailWithError: URLError(errorCode)
            )
            markFinished()
        case .delayedSuccess(
            let statusCode,
            let data,
            let headers,
            let delay
        ):
            DispatchQueue.global().asyncAfter(
                deadline: .now() + delay
            ) { [weak self] in
                self?.deliver(
                    statusCode: statusCode,
                    data: data,
                    headers: headers,
                    finishesLoading: true
                )
            }
        case .redirect(let statusCode, let location):
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Location": location.absoluteString
                    ]
                )
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.badServerResponse)
                )
                markFinished()
                return
            }
            var redirectedRequest = URLRequest(url: location)
            redirectedRequest.httpMethod = request.httpMethod
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirectedRequest,
                redirectResponse: response
            )
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cancelled)
            )
            markFinished()
        case .none:
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unknown)
            )
            markFinished()
        }
    }

    override func stopLoading() {
        guard let url = request.url else {
            return
        }
        Self.lock.lock()
        let handler = Self.onStopLoading
        Self.lock.unlock()
        handler?(url)
        markFinished()
    }

    private func deliver(
        statusCode: Int,
        data: Data,
        headers: [String: String],
        finishesLoading: Bool
    ) {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            markFinished()
            return
        }
        guard isRequestActive() else {
            return
        }
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            markFinished()
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        if finishesLoading {
            client?.urlProtocolDidFinishLoading(self)
            markFinished()
        }
    }

    private func markActive() {
        lifecycleLock.lock()
        isActive = true
        lifecycleLock.unlock()

        Self.lock.lock()
        Self.activeRequestCount += 1
        Self.maximumActiveRequestCountStorage = max(
            Self.maximumActiveRequestCountStorage,
            Self.activeRequestCount
        )
        Self.lock.unlock()
    }

    private func isRequestActive() -> Bool {
        lifecycleLock.lock()
        defer {
            lifecycleLock.unlock()
        }
        return isActive
    }

    private func markFinished() {
        lifecycleLock.lock()
        let wasActive = isActive
        isActive = false
        lifecycleLock.unlock()
        guard wasActive else {
            return
        }
        Self.lock.lock()
        Self.activeRequestCount = max(
            0,
            Self.activeRequestCount - 1
        )
        Self.lock.unlock()
    }
}
