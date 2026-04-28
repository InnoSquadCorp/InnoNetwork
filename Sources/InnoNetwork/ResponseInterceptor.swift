import Foundation

public protocol ResponseInterceptor: Sendable {
    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response
}
