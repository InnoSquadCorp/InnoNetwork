import Foundation

public protocol RequestInterceptor: Sendable {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest
}
