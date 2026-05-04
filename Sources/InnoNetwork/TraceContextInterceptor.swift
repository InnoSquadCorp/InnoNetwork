import Foundation

/// Parsed W3C Trace Context value carried in the `traceparent` header.
///
/// The wire shape is `version-trace-id-parent-id-trace-flags`, for example
/// `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`.
public struct W3CTraceContext: Sendable, Equatable {
    public let version: String
    public let traceID: String
    public let parentID: String
    public let traceFlags: String

    public var traceparent: String {
        "\(version)-\(traceID)-\(parentID)-\(traceFlags)"
    }

    public init?(traceparent: String) {
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let version = String(parts[0]).lowercased()
        let traceID = String(parts[1]).lowercased()
        let parentID = String(parts[2]).lowercased()
        let traceFlags = String(parts[3]).lowercased()
        guard Self.isLowercaseHex(version, count: 2),
            Self.isLowercaseHex(traceID, count: 32),
            Self.isLowercaseHex(parentID, count: 16),
            Self.isLowercaseHex(traceFlags, count: 2),
            traceID != String(repeating: "0", count: 32),
            parentID != String(repeating: "0", count: 16)
        else {
            return nil
        }
        self.version = version
        self.traceID = traceID
        self.parentID = parentID
        self.traceFlags = traceFlags
    }

    public init(traceID: String, parentID: String, sampled: Bool = true) {
        self.version = "00"
        self.traceID = Self.normalizedHex(traceID, length: 32) ?? Self.makeTraceID()
        self.parentID = Self.normalizedHex(parentID, length: 16) ?? Self.makeParentID()
        self.traceFlags = sampled ? "01" : "00"
    }

    public static func generated(sampled: Bool = true) -> W3CTraceContext {
        W3CTraceContext(traceID: makeTraceID(), parentID: makeParentID(), sampled: sampled)
    }

    private static func makeTraceID() -> String {
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return value == String(repeating: "0", count: 32) ? makeTraceID() : value
    }

    private static func makeParentID() -> String {
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(value.prefix(16))
    }

    private static func normalizedHex(_ value: String, length: Int) -> String? {
        let normalized = value.lowercased()
        guard isLowercaseHex(normalized, count: length),
            normalized != String(repeating: "0", count: length)
        else {
            return nil
        }
        return normalized
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        guard value.count == count else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// Request interceptor that writes W3C Trace Context headers.
///
/// Existing `traceparent` values on the request are preserved. Otherwise the
/// interceptor first tries to propagate ``NetworkContext/traceID`` when it is
/// already a valid W3C `traceparent`; when only a 32-character trace id is
/// bound, it creates a fresh parent span id for that trace. If no usable
/// context exists and `generateWhenMissing` is `true`, it creates a new
/// sampled trace.
public struct TraceContextInterceptor: RequestInterceptor {
    public let generateWhenMissing: Bool
    public let sampled: Bool
    public let tracestate: String?

    public init(
        generateWhenMissing: Bool = true,
        sampled: Bool = true,
        tracestate: String? = nil
    ) {
        self.generateWhenMissing = generateWhenMissing
        self.sampled = sampled
        self.tracestate = tracestate
    }

    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        guard urlRequest.value(forHTTPHeaderField: "traceparent") == nil else {
            return urlRequest
        }

        guard let context = makeContext() else { return urlRequest }
        var request = urlRequest
        request.setValue(context.traceparent, forHTTPHeaderField: "traceparent")
        if request.value(forHTTPHeaderField: "tracestate") == nil, let tracestate {
            request.setValue(tracestate, forHTTPHeaderField: "tracestate")
        }
        return request
    }

    private func makeContext() -> W3CTraceContext? {
        if let traceID = NetworkContext.current.traceID {
            if let context = W3CTraceContext(traceparent: traceID) {
                return context
            }
            return W3CTraceContext(traceID: traceID, parentID: UUID().uuidString, sampled: sampled)
        }
        guard generateWhenMissing else { return nil }
        return .generated(sampled: sampled)
    }
}
