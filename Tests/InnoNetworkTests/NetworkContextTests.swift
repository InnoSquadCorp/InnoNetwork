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
}
