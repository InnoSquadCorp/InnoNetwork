import CryptoKit
import Foundation
import InnoNetwork
import os

/// Recording strategy for ``VCRURLSession``.
public enum VCRMode: Sendable, Equatable {
    /// Serve responses from the in-memory cassette and fail unmatched requests.
    case replay
    /// Forward requests to a backing session and append redacted interactions to the cassette.
    case record
}


/// Redaction settings applied before requests and responses are stored in a cassette.
public struct VCRRedactionPolicy: Sendable, Equatable {
    /// Case-insensitive header names whose values should be replaced.
    public var sensitiveHeaderNames: Set<String>
    /// Case-insensitive query item names whose values should be replaced.
    public var sensitiveQueryItemNames: Set<String>
    /// Replacement marker written into the cassette.
    public var replacement: String

    /// Creates a redaction policy.
    public init(
        sensitiveHeaderNames: Set<String> = [
            "authorization",
            "cookie",
            "proxy-authorization",
            "set-cookie",
            "x-api-key",
        ],
        sensitiveQueryItemNames: Set<String> = ["access_token", "api_key", "token"],
        replacement: String = "<redacted>"
    ) {
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        self.sensitiveQueryItemNames = Set(sensitiveQueryItemNames.map { $0.lowercased() })
        self.replacement = replacement
    }

    /// Privacy-first default policy covering common auth, cookie, and API-key fields.
    public static var `default`: Self { VCRRedactionPolicy() }
}


/// Redacted request identity used for cassette matching.
public struct VCRRequest: Codable, Hashable, Sendable {
    /// HTTP method, defaulting to `GET` when the request does not specify one.
    public let method: String
    /// Absolute URL string after configured query redaction.
    public let url: String
    /// Lower-cased header map after configured header redaction.
    public let headers: [String: String]
    /// SHA-256 hex digest of the request body, when one is present.
    public let bodySHA256: String?

    /// Creates a cassette request identity.
    public init(method: String, url: String, headers: [String: String], bodySHA256: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.bodySHA256 = bodySHA256
    }
}


/// Recorded HTTP response payload.
public struct VCRResponse: Codable, Equatable, Sendable {
    /// HTTP status code to replay.
    public let statusCode: Int
    /// Response headers after configured redaction.
    public let headers: [String: String]
    /// Response body bytes.
    public let body: Data

    /// Creates a cassette response.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}


/// One request/response pair in a cassette.
public struct VCRInteraction: Codable, Equatable, Sendable {
    /// Redacted request identity.
    public let request: VCRRequest
    /// Recorded response for the request.
    public let response: VCRResponse

    /// Creates a cassette interaction.
    public init(request: VCRRequest, response: VCRResponse) {
        self.request = request
        self.response = response
    }
}


/// Collection of recorded HTTP interactions.
public struct VCRCassette: Codable, Equatable, Sendable {
    /// Ordered interactions used for replay.
    public var interactions: [VCRInteraction]

    /// Creates a cassette.
    public init(interactions: [VCRInteraction] = []) {
        self.interactions = interactions
    }

    /// Loads a cassette from JSON.
    public static func load(
        from url: URL,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> VCRCassette {
        try decoder.decode(VCRCassette.self, from: Data(contentsOf: url))
    }

    /// Writes the cassette as deterministic, pretty-printed JSON.
    public func write(to url: URL) throws {
        try write(to: url, encoder: Self.makeEncoder())
    }

    /// Writes the cassette with a caller-provided encoder.
    public func write(to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}


/// URLSessionProtocol wrapper that records and replays deterministic HTTP cassettes.
public final class VCRURLSession: URLSessionProtocol, Sendable {
    private struct State {
        var cassette: VCRCassette
        var replayCursor: Int
    }

    private let mode: VCRMode
    private let recordingSession: (any URLSessionProtocol)?
    private let redactionPolicy: VCRRedactionPolicy
    private let state: OSAllocatedUnfairLock<State>

    /// Creates a recording or replaying URL session wrapper.
    public init(
        cassette: VCRCassette = VCRCassette(),
        mode: VCRMode,
        recordingSession: (any URLSessionProtocol)? = nil,
        redactionPolicy: VCRRedactionPolicy = .default
    ) {
        self.mode = mode
        self.recordingSession = recordingSession
        self.redactionPolicy = redactionPolicy
        self.state = OSAllocatedUnfairLock(
            initialState: State(cassette: cassette, replayCursor: cassette.interactions.startIndex)
        )
    }

    /// Current cassette snapshot.
    public var cassette: VCRCassette {
        state.withLock { $0.cassette }
    }

    /// Executes the request by recording through the backing session or replaying from the cassette.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let sanitizedRequest = sanitize(request)
        switch mode {
        case .replay:
            // Strictly sequential replay: only the interaction at the cursor
            // is eligible. A request that doesn't match the next-expected
            // entry is a cassette mismatch — the decoder must not skip ahead
            // and silently consume a later interaction.
            let interaction: VCRInteraction? = state.withLock { state -> VCRInteraction? in
                let cursor = state.replayCursor
                guard cursor < state.cassette.interactions.endIndex else {
                    return nil
                }
                let expected = state.cassette.interactions[cursor]
                guard expected.request == sanitizedRequest else {
                    return nil
                }
                state.replayCursor = state.cassette.interactions.index(after: cursor)
                return expected
            }
            guard let interaction else {
                throw NetworkError.configuration(
                    reason: .invalidRequest(
                        "No VCR cassette interaction matched \(sanitizedRequest.method) \(sanitizedRequest.url)."
                    ))
            }
            return try makeURLResponse(from: interaction.response, url: request.url)

        case .record:
            guard let recordingSession else {
                throw NetworkError.configuration(
                    reason: .invalidRequest(
                        "VCRURLSession record mode requires a recordingSession."
                    ))
            }
            let (data, response) = try await recordingSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: 3002,
                        message: "VCRURLSession received a non-HTTP response while recording \(request.url?.absoluteString ?? "<unknown>")."
                    ),
                    nil
                )
            }
            let recorded = VCRInteraction(
                request: sanitizedRequest,
                response: VCRResponse(
                    statusCode: httpResponse.statusCode,
                    headers: sanitizeHeaders(httpResponse.allHeaderFields),
                    body: data
                )
            )
            state.withLock { $0.cassette.interactions.append(recorded) }
            return (data, response)
        }
    }

    private func makeURLResponse(from response: VCRResponse, url: URL?) throws -> (Data, URLResponse) {
        guard let url else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Cannot replay VCR response without a request URL."))
        }
        guard
            let http = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )
        else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Recorded VCR response is not a valid HTTP response."))
        }
        return (response.body, http)
    }

    /// Builds the cassette-shape ``VCRRequest`` used for matching. The body
    /// is reduced to a SHA-256 hex digest so cassettes never persist raw
    /// payloads — sensitive request bodies stay out of recording files.
    ///
    /// - Important: `URLRequest.httpBodyStream`-based uploads have a `nil`
    ///   `httpBody`, so stream uploads are matched only by method, URL, and
    ///   headers. Cassettes targeting stream-uploaded requests should not
    ///   rely on body-content matching for replay disambiguation.
    private func sanitize(_ request: URLRequest) -> VCRRequest {
        VCRRequest(
            method: request.httpMethod ?? "GET",
            url: sanitizedURLString(request.url),
            headers: sanitizeHeaders(request.allHTTPHeaderFields ?? [:]),
            bodySHA256: request.httpBody.map(sha256Hex)
        )
    }

    private func sanitizedURLString(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url?.absoluteString ?? ""
        }
        components.queryItems = components.queryItems?.map { item in
            guard redactionPolicy.sensitiveQueryItemNames.contains(item.name.lowercased()) else {
                return item
            }
            return URLQueryItem(name: item.name, value: redactionPolicy.replacement)
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func sanitizeHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in headers {
            guard let name = key as? String else { continue }
            let lowered = name.lowercased()
            let value = String(describing: value)
            sanitized[lowered] =
                redactionPolicy.sensitiveHeaderNames.contains(lowered)
                ? redactionPolicy.replacement
                : value
        }
        return sanitized
    }

    private func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        sanitizeHeaders(Dictionary(uniqueKeysWithValues: headers.map { ($0.key as AnyHashable, $0.value as Any) }))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
