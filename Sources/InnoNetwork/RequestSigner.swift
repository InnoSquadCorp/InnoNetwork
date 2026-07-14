import Foundation

/// Read-only representation of the bytes that an outgoing request will send.
///
/// A signer receives this value only after request interceptors and the active
/// refresh-token policy have finished adapting the request. File-backed bodies
/// point at an InnoNetwork-owned immutable snapshot, not at the caller's source
/// file, so the bytes hashed by a signer are the same bytes handed to
/// `URLSession.upload(for:fromFile:)`.
public enum RequestBody: Sendable {
    /// The request has no body.
    case none
    /// The request body is held in memory.
    case data(Data)
    /// The request body will be uploaded from this stable file snapshot.
    case file(URL)
}

/// Produces headers for the final outgoing request without being able to
/// replace its URL, method, or body.
///
/// Signers run after configuration-level and endpoint-level
/// ``RequestInterceptor`` values and after ``RefreshTokenPolicy`` applies its
/// current token. Configuration signers run first, followed by endpoint
/// signers. Each signer sees headers emitted by the preceding signer and may
/// return only headers, which the executor applies with single-value
/// replacement semantics.
///
/// The stage runs once per retry attempt and again after a refresh-token replay
/// so signatures always cover the request that reaches the transport.
///
/// Signed requests bypass response caching and in-flight request coalescing.
/// A signer may establish the authentication principal, so sharing under the
/// unsigned request identity could return one principal's response to another.
/// Circuit-breaker health remains keyed by the unsigned origin because it
/// represents transport availability rather than response identity.
public protocol RequestSigner: Sendable {
    /// Returns signature or late-authentication headers for `request`.
    ///
    /// - Parameters:
    ///   - request: The final adapted request envelope. Mutating this local
    ///     value cannot alter the executor-owned request.
    ///   - body: The exact body bytes that the transport will send.
    /// - Returns: Headers to merge into the outgoing request.
    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders
}

package extension RequestBody {
    /// Streams the body through `consume` without forcing file-backed uploads
    /// into one large in-memory allocation.
    func forEachChunk(
        byteCount: Int = 64 * 1024,
        _ consume: (Data) throws -> Void
    ) throws {
        switch self {
        case .none:
            return
        case .data(let data):
            try Task.checkCancellation()
            try consume(data)
        case .file(let fileURL):
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: byteCount), !chunk.isEmpty else {
                    return
                }
                try consume(chunk)
            }
        }
    }
}

package extension BodySource {
    func signingBody(for request: URLRequest) throws -> RequestBody {
        switch self {
        case .file(let fileURL, _):
            return .file(fileURL)
        case .inline:
            guard request.httpBodyStream == nil else {
                throw NetworkError.configuration(
                    reason: .invalidRequest(
                        "RequestSigner cannot inspect URLRequest.httpBodyStream. Use RequestPayload.data(_:) or RequestPayload.fileURL(_:contentType:) for signed requests."
                    )
                )
            }
            if let body = request.httpBody {
                return .data(body)
            }
            return .none
        }
    }
}

package extension URLRequest {
    func preparingForSignedTransport() -> URLRequest {
        var prepared = self
        prepared.cachePolicy = .reloadIgnoringLocalCacheData

        let existing = prepared.value(forHTTPHeaderField: "Cache-Control")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let containsNoStore =
            existing?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("no-store") == true
        if !containsNoStore {
            let value = existing.flatMap { $0.isEmpty ? nil : "\($0), no-store" } ?? "no-store"
            prepared.setValue(value, forHTTPHeaderField: "Cache-Control")
        }
        return prepared
    }
}
