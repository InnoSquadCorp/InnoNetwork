import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct HLSHTTPTransfer: Sendable {
    package let response: URLResponse
    package let finalURL: URL
    package let chunks: AsyncThrowingStream<Data, Error>
    package let cancel: @Sendable () -> Void
}

package struct HLSHTTPClient: Sendable {
    private let session: URLSession
    private let requestContext: NetworkRequestContext
    private let requestPolicy: HLSRequestPolicy

    init(
        session: URLSession,
        requestContext: NetworkRequestContext,
        requestAdapter:
            @escaping @Sendable (URLRequest) async throws -> URLRequest
    ) {
        self.session = session
        self.requestContext = requestContext
        self.requestPolicy = HLSRequestPolicy { request, _ in
            try await requestAdapter(request)
        }
    }

    init(
        session: URLSession,
        requestContext: NetworkRequestContext,
        requestPolicy: HLSRequestPolicy
    ) {
        self.session = session
        self.requestContext = requestContext
        self.requestPolicy = requestPolicy
    }

    var eventObservers: [any NetworkEventObserving] {
        requestContext.eventObservers
    }

    package func transfer(
        _ request: URLRequest,
        purpose: HLSRequestPurpose,
        resourceIndex: Int? = nil,
        maximumBytes: Int,
        requestID: UUID = UUID(),
        retryIndex: Int = 0,
        disablesCaching: Bool = false
    ) async throws -> HLSHTTPTransfer {
        let context = HLSRequestContext(
            requestID: requestID,
            purpose: purpose,
            resourceIndex: resourceIndex,
            retryIndex: retryIndex
        )
        await requestPolicy.emit(.requestStarted(context))

        var adaptedRequest: URLRequest
        do {
            adaptedRequest = try await requestPolicy.adapt(
                request,
                context: context
            )
        } catch {
            await requestPolicy.emit(
                .requestFailed(
                    context,
                    failure: Self.isCancellation(error)
                        ? .cancellation
                        : .adaptation
                )
            )
            throw error
        }
        if disablesCaching {
            adaptedRequest.cachePolicy = .reloadIgnoringLocalCacheData
            adaptedRequest.setValue(
                "no-store",
                forHTTPHeaderField: "Cache-Control"
            )
        }
        let admittedRequest: URLRequest
        do {
            admittedRequest = try NetworkURLAdmission.validate(
                adaptedRequest,
                policy: .http(
                    allowsInsecure: requestContext.allowsInsecureHTTP
                )
            )
        } catch {
            await requestPolicy.emit(
                .requestFailed(
                    context,
                    failure: Self.isCancellation(error)
                        ? .cancellation
                        : .urlAdmission
                )
            )
            throw error
        }
        let transfer: ChunkedTransfer
        do {
            transfer = try await session.chunkedTransfer(
                for: admittedRequest,
                context: requestContext.replacingCorrelation(
                    requestID: requestID,
                    retryIndex: retryIndex
                ),
                maxBytes: Int64(maximumBytes)
            )
        } catch {
            await requestPolicy.emit(
                .requestFailed(
                    context,
                    failure: Self.isCancellation(error)
                        ? .cancellation
                        : .transport
                )
            )
            throw error
        }
        let finalURL =
            transfer.finalRequest?.url
            ?? transfer.response.url
            ?? admittedRequest.url
        guard let finalURL else {
            transfer.cancel()
            await requestPolicy.emit(
                .requestFailed(
                    context,
                    failure: .transport
                )
            )
            throw HLSDownloadError.invalidPlaylist
        }
        await requestPolicy.emit(
            .responseReceived(
                context,
                statusCode: (transfer.response as? HTTPURLResponse)?.statusCode
            )
        )
        return HLSHTTPTransfer(
            response: transfer.response,
            finalURL: finalURL,
            chunks: transfer.chunks,
            cancel: transfer.cancel
        )
    }

    package static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return true
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NSURLErrorDomain
            && cocoaError.code == NSURLErrorCancelled
    }

    package static func isBodyLimitExceeded(_ error: Error) -> Bool {
        if let networkError = error as? NetworkError {
            if case .underlying(let underlyingError, _) = networkError {
                return underlyingError.domain == NetworkError.errorDomain
                    && underlyingError.code
                        == NetworkErrorCode.responseBodyLimitExceeded.rawValue
            }
            return false
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NetworkError.errorDomain
            && cocoaError.code
                == NetworkErrorCode.responseBodyLimitExceeded.rawValue
    }
}
