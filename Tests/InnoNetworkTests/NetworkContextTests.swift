import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct NetworkContextTests {
    @Test
    func defaultContextHasNoIdentifiers() {
        let context = NetworkContext.current
        #expect(context.traceID == nil)
        #expect(context.correlationID == nil)
        #expect(context.baggage.isEmpty)
    }

    @Test
    func taskLocalBindingIsVisibleInsideScope() {
        NetworkContext.$current.withValue(
            NetworkContext(traceID: "trace-1", correlationID: "corr-1")
        ) {
            #expect(NetworkContext.current.traceID == "trace-1")
            #expect(NetworkContext.current.correlationID == "corr-1")
        }
        // Outside the scope the binding is restored to the default empty
        // value so the test suite does not leak context into other cases.
        #expect(NetworkContext.current.traceID == nil)
    }

    @Test
    func interceptorWritesContextValuesAsHeaders() async throws {
        let interceptor = CorrelationIDInterceptor()
        let baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)

        let adapted = try await NetworkContext.$current.withValue(
            NetworkContext(traceID: "abc", correlationID: "def")
        ) {
            try await interceptor.adapt(baseRequest)
        }

        #expect(adapted.value(forHTTPHeaderField: "X-Trace-ID") == "abc")
        #expect(adapted.value(forHTTPHeaderField: "X-Correlation-ID") == "def")
    }

    @Test
    func interceptorIsNoOpWhenContextIsEmpty() async throws {
        let interceptor = CorrelationIDInterceptor()
        let baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)

        let adapted = try await interceptor.adapt(baseRequest)

        #expect(adapted.value(forHTTPHeaderField: "X-Trace-ID") == nil)
        #expect(adapted.value(forHTTPHeaderField: "X-Correlation-ID") == nil)
    }

    @Test
    func customHeaderNamesArePassedThrough() async throws {
        let interceptor = CorrelationIDInterceptor(
            traceHeader: "traceparent",
            correlationHeader: "X-Request-Id"
        )
        let baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)

        let adapted = try await NetworkContext.$current.withValue(
            NetworkContext(traceID: "00-abc-def-01", correlationID: "req-77")
        ) {
            try await interceptor.adapt(baseRequest)
        }

        #expect(adapted.value(forHTTPHeaderField: "traceparent") == "00-abc-def-01")
        #expect(adapted.value(forHTTPHeaderField: "X-Request-Id") == "req-77")
    }

    @Test
    func traceContextInterceptorPreservesExistingTraceparent() async throws {
        let interceptor = TraceContextInterceptor()
        var baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)
        baseRequest.setValue(
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            forHTTPHeaderField: "traceparent"
        )

        let adapted = try await interceptor.adapt(baseRequest)

        #expect(
            adapted.value(forHTTPHeaderField: "traceparent")
                == "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        )
    }

    @Test
    func traceContextInterceptorPropagatesTaskLocalTraceparent() async throws {
        let interceptor = TraceContextInterceptor()
        let baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)
        let traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

        let adapted = try await NetworkContext.$current.withValue(
            NetworkContext(traceID: traceparent)
        ) {
            try await interceptor.adapt(baseRequest)
        }

        #expect(adapted.value(forHTTPHeaderField: "traceparent") == traceparent)
    }

    @Test
    func traceContextInterceptorPropagatesTaskLocalTraceID() async throws {
        let interceptor = TraceContextInterceptor()
        let baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)
        let traceID = "4bf92f3577b34da6a3ce929d0e0e4736"

        let adapted = try await NetworkContext.$current.withValue(
            NetworkContext(traceID: traceID)
        ) {
            try await interceptor.adapt(baseRequest)
        }
        let traceparent = try #require(adapted.value(forHTTPHeaderField: "traceparent"))
        let context = try #require(W3CTraceContext(traceparent: traceparent))

        #expect(context.traceID == traceID)
    }

    @Test
    func traceContextInterceptorDoesNotGenerateForInvalidTaskLocalTraceWhenDisabled() async throws {
        let interceptor = TraceContextInterceptor(generateWhenMissing: false)
        let baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)

        let adapted = try await NetworkContext.$current.withValue(
            NetworkContext(traceID: "not-a-w3c-trace")
        ) {
            try await interceptor.adapt(baseRequest)
        }

        #expect(adapted.value(forHTTPHeaderField: "traceparent") == nil)
    }

    @Test
    func traceContextInterceptorGeneratesTraceparentWhenMissing() async throws {
        let interceptor = TraceContextInterceptor(tracestate: "vendor=state")
        let baseRequest = URLRequest(url: URL(string: "https://example.invalid/x")!)

        let adapted = try await interceptor.adapt(baseRequest)
        let traceparent = try #require(adapted.value(forHTTPHeaderField: "traceparent"))

        #expect(W3CTraceContext(traceparent: traceparent) != nil)
        #expect(adapted.value(forHTTPHeaderField: "tracestate") == "vendor=state")
    }
}
