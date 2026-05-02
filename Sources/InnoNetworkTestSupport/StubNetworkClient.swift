import Foundation
import InnoNetwork
import os

/// Controls how ``StubNetworkClient`` delivers a registered response.
public enum StubBehavior: Sendable, Equatable {
    /// Disable the registered stub and use the fallback client when present.
    case never

    /// Resolve the stub immediately.
    case immediate

    /// Resolve the stub after sleeping the supplied duration.
    case delayed(seconds: TimeInterval)
}


/// Stable key used by ``StubNetworkClient`` to match typed requests.
public struct StubRequestKey: Hashable, Sendable {
    public let method: String
    public let path: String

    public init(method: HTTPMethod, path: String) {
        self.method = method.rawValue
        self.path = path
    }

    public init<Request: APIDefinition>(_ request: Request) {
        self.init(method: request.method, path: request.path)
    }
}


/// Explicit test/preview client for returning canned responses without
/// changing production ``APIDefinition`` behavior.
public final class StubNetworkClient: NetworkClient, Sendable {
    private struct StubEntry: Sendable {
        let response: any Sendable
        let behavior: StubBehavior
    }

    private let fallback: (any NetworkClient)?
    private let stubs = OSAllocatedUnfairLock<[StubRequestKey: StubEntry]>(initialState: [:])

    public init(fallback: (any NetworkClient)? = nil) {
        self.fallback = fallback
    }

    public func register<Response: Decodable & Sendable>(
        _ response: Response,
        for key: StubRequestKey,
        behavior: StubBehavior = .immediate
    ) {
        stubs.withLock {
            $0[key] = StubEntry(response: response, behavior: behavior)
        }
    }

    public func register<Request: APIDefinition>(
        _ response: Request.APIResponse,
        for request: Request,
        behavior: StubBehavior = .immediate
    ) {
        register(response, for: StubRequestKey(request), behavior: behavior)
    }

    public func request<Request: APIDefinition>(_ request: Request) async throws -> Request.APIResponse {
        let key = StubRequestKey(request)
        if let entry = stubs.withLock({ $0[key] }) {
            switch entry.behavior {
            case .never:
                break
            case .immediate:
                return try cast(entry.response, for: key)
            case .delayed(let seconds):
                if seconds > 0 {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch is CancellationError {
                        throw NetworkError.cancelled
                    }
                }
                return try cast(entry.response, for: key)
            }
        }

        if let fallback {
            return try await fallback.request(request)
        }

        throw NetworkError.invalidRequestConfiguration(
            "No stub registered for \(request.method.rawValue) \(request.path)."
        )
    }

    public func request<Request: APIDefinition>(
        _ request: Request,
        tag: CancellationTag?
    ) async throws -> Request.APIResponse {
        let key = StubRequestKey(request)
        if let entry = stubs.withLock({ $0[key] }) {
            switch entry.behavior {
            case .never:
                break
            case .immediate:
                return try cast(entry.response, for: key)
            case .delayed(let seconds):
                if seconds > 0 {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch is CancellationError {
                        throw NetworkError.cancelled
                    }
                }
                return try cast(entry.response, for: key)
            }
        }

        if let fallback {
            return try await fallback.request(request, tag: tag)
        }

        throw NetworkError.invalidRequestConfiguration(
            "No stub registered for \(request.method.rawValue) \(request.path)."
        )
    }

    public func upload<Request: MultipartAPIDefinition>(_ request: Request) async throws -> Request.APIResponse {
        if let fallback {
            return try await fallback.upload(request)
        }

        throw NetworkError.invalidRequestConfiguration(
            "StubNetworkClient does not provide multipart upload stubs without a fallback client."
        )
    }

    public func upload<Request: MultipartAPIDefinition>(
        _ request: Request,
        tag: CancellationTag?
    ) async throws -> Request.APIResponse {
        if let fallback {
            return try await fallback.upload(request, tag: tag)
        }

        throw NetworkError.invalidRequestConfiguration(
            "StubNetworkClient does not provide multipart upload stubs without a fallback client."
        )
    }

    private func cast<Response: Decodable & Sendable>(
        _ response: any Sendable,
        for key: StubRequestKey
    ) throws -> Response {
        guard let typed = response as? Response else {
            throw NetworkError.invalidRequestConfiguration(
                "Registered stub for \(key.method) \(key.path) has the wrong response type."
            )
        }
        return typed
    }
}
