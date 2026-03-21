import Foundation
import InnoNetwork


public protocol ProtobufNetworkClient: NetworkClient {
    func protobufRequest<T: ProtobufAPIDefinition>(_ request: T) async throws -> T.APIResponse
}

extension DefaultNetworkClient: ProtobufNetworkClient {
    public func protobufRequest<T: ProtobufAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performTypedRequest(ProtobufSingleRequestExecutable(base: request))
    }
}
