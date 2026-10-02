import Foundation

/// A named, Sendable endpoint backed by a buffered codec rather than Codable.
/// Prefer a companion's macro to synthesise this conformance. Manual conformers
/// must keep their method, path and authentication equal to the returned request.
/// Building the request must only prepare deferred encoders, never perform I/O.
public protocol EncodedAPIDefinition: Sendable {
    associatedtype APIResponse: Sendable
    var method: HTTPMethod { get }
    var path: String { get }
    var sessionAuthentication: SessionAuthentication { get }
    func makeEncodedRequest() throws(NetworkError) -> EncodedRequest<APIResponse>
}

public extension EncodedRequestClient {
    /// Executes a named binary endpoint through this client's existing pipeline.
    func request<Definition: EncodedAPIDefinition>(
        _ definition: Definition, tag: CancellationTag? = nil
    ) async throws(NetworkError) -> Definition.APIResponse {
        guard !Task.isCancelled else { throw .cancelled }
        let metadata = EncodedDefinitionMetadata(definition)
        let request = try metadata.prepare(definition)
        return try await self.request(request, tag: tag)
    }
}

/// Captured once before execution so operation failure/replay metadata cannot
/// disagree with what a manual factory actually sends. Never includes payloads.
struct EncodedDefinitionMetadata: Sendable {
    let method: HTTPMethod
    let path: String
    let authentication: SessionAuthentication

    init(_ definition: some EncodedAPIDefinition) {
        method = definition.method
        path = definition.path
        authentication = definition.sessionAuthentication
    }

    func prepare<Definition: EncodedAPIDefinition>(
        _ definition: Definition
    ) throws(NetworkError) -> EncodedRequest<Definition.APIResponse> {
        guard !Task.isCancelled else { throw .cancelled }
        let request = try definition.makeEncodedRequest()
        guard !Task.isCancelled else { throw .cancelled }
        guard request.method == method, request.path == path,
            request.sessionAuthentication == authentication
        else {
            throw .configuration(reason: .invalidRequest("Encoded endpoint metadata does not match its request."))
        }
        return request
    }
}

public extension EncodedRequestOptions {
    /// Appends ordinary HTTP query values, preserving existing item order and
    /// duplicate keys. Encoding errors expose no input values or foreign payload.
    func addingQuery<Query: Encodable & Sendable>(
        _ query: Query, encoder: URLQueryEncoder = .init()
    ) throws(NetworkError) -> Self {
        guard !Task.isCancelled else { throw .cancelled }
        do {
            var copy = self
            copy.queryItems += try encoder.encode(query)
            guard !Task.isCancelled else { throw NetworkError.cancelled }
            return copy
        } catch  where NetworkError.isCancellation(error) {
            throw .cancelled
        } catch {
            throw .configuration(reason: .invalidPayload(.encoding))
        }
    }
}
