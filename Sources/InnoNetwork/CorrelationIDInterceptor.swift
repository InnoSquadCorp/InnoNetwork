import Foundation

/// Request interceptor that copies values from the surrounding
/// ``NetworkContext/current`` onto the outgoing `URLRequest` as headers.
///
/// Add it to the session-level interceptor chain on
/// ``NetworkConfiguration/requestInterceptors`` so every request picks up
/// the trace/correlation IDs bound by the caller without each
/// ``APIDefinition`` re-implementing the wiring:
///
/// ```swift
/// let configuration = NetworkConfiguration.advanced(baseURL: baseURL) {
///     $0.requestInterceptors = [CorrelationIDInterceptor()]
/// }
///
/// NetworkContext.$current.withValue(
///     NetworkContext(
///         traceID: traceID,
///         correlationID: correlationID
///     )
/// ) {
///     Task { try await client.request(GetUser(id: id)) }
/// }
/// ```
///
/// Header names default to `X-Trace-ID` and `X-Correlation-ID`. Pass custom
/// names if your gateway expects a different convention (e.g. the W3C
/// `traceparent` header for distributed tracing).
public struct CorrelationIDInterceptor: RequestInterceptor {
    public let traceHeader: String
    public let correlationHeader: String

    public init(
        traceHeader: String = "X-Trace-ID",
        correlationHeader: String = "X-Correlation-ID"
    ) {
        self.traceHeader = traceHeader
        self.correlationHeader = correlationHeader
    }

    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        let context = NetworkContext.current
        var request = urlRequest
        if let traceID = context.traceID, !traceID.isEmpty {
            request.setValue(traceID, forHTTPHeaderField: traceHeader)
        }
        if let correlationID = context.correlationID, !correlationID.isEmpty {
            request.setValue(correlationID, forHTTPHeaderField: correlationHeader)
        }
        return request
    }
}
