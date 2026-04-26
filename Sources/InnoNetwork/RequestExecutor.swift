import Foundation


package struct RequestExecutor {
    private let session: URLSessionProtocol
    private let eventHub: NetworkEventHub

    package init(session: URLSessionProtocol, eventHub: NetworkEventHub) {
        self.session = session
        self.eventHub = eventHub
    }

    package func execute<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration,
        requestBuilder: RequestBuilder,
        retryIndex: Int,
        requestID: UUID
    ) async throws -> D.APIResponse {
        try Task.checkCancellation()

        do {
            var request = try requestBuilder.build(executable, configuration: configuration)
            await notifyRequestStart(request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            for interceptor in executable.requestInterceptors {
                request = try await interceptor.adapt(request)
            }
            await notifyRequestAdapted(request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            executable.logger.log(request: request)

            let context = NetworkRequestContext(
                requestID: requestID,
                retryIndex: retryIndex,
                metricsReporter: configuration.metricsReporter,
                trustPolicy: configuration.trustPolicy,
                eventObservers: configuration.eventObservers
            )
            let (data, response) = try await session.data(for: request, context: context)

            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.nonHTTPResponse(response)
            }
            await eventHub.publish(
                .responseReceived(
                    requestID: requestID,
                    statusCode: httpResponse.statusCode,
                    byteCount: data.count
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            var networkResponse = Response(
                statusCode: httpResponse.statusCode,
                data: data,
                request: request,
                response: httpResponse
            )

            for interceptor in executable.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: request)
            }

            guard configuration.acceptableStatusCodes.contains(httpResponse.statusCode) else {
                throw NetworkError.statusCode(networkResponse)
            }

            executable.logger.log(response: networkResponse, isError: false)
            await eventHub.publish(
                .requestFinished(
                    requestID: requestID,
                    statusCode: httpResponse.statusCode,
                    byteCount: data.count
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            return try executable.decode(data: data, response: networkResponse)
        } catch let error as NetworkError {
            executable.logger.log(error: error)
            await notifyFailure(error, requestID: requestID, configuration: configuration)
            throw error
        } catch where NetworkError.isCancellation(error) {
            executable.logger.log(error: .cancelled)
            await notifyFailure(.cancelled, requestID: requestID, configuration: configuration)
            throw NetworkError.cancelled
        } catch {
            let networkError = toNetworkError(error)
            executable.logger.log(error: networkError)
            await notifyFailure(networkError, requestID: requestID, configuration: configuration)
            throw networkError
        }
    }

    private func notifyRequestStart(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await eventHub.publish(
            .requestStart(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    private func notifyRequestAdapted(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await eventHub.publish(
            .requestAdapted(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    private func notifyFailure(
        _ networkError: NetworkError,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        let nsError = networkError as NSError
        await eventHub.publish(
            .requestFailed(
                requestID: requestID,
                errorCode: nsError.code,
                message: networkError.localizedDescription
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    private func toNetworkError(_ error: Error) -> NetworkError {
        if let trustEvaluationError = error as? TrustEvaluationError {
            switch trustEvaluationError {
            case .failed(let reason, _):
                return .trustEvaluationFailed(reason)
            }
        }

        if NetworkError.isCancellation(error) {
            return .cancelled
        }

        return .underlying(SendableUnderlyingError(error), nil)
    }
}
