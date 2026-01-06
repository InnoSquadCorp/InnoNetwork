import Foundation
import OSLog


private let dateFormatterCache: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

private let sharedDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .formatted(dateFormatterCache)
    return decoder
}()


public protocol APIDefinition: Sendable {
    associatedtype Parameter: Encodable & Sendable
    associatedtype APIResponse: Decodable & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }

    var contentType: ContentType { get }
    var decoder: JSONDecoder { get }
    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
}


public protocol MultipartAPIDefinition: Sendable {
    associatedtype APIResponse: Decodable & Sendable

    var multipartFormData: MultipartFormData { get }
    var method: HTTPMethod { get }
    var path: String { get }

    var decoder: JSONDecoder { get }
    var headers: HTTPHeaders { get }

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
}


public extension MultipartAPIDefinition {
    var decoder: JSONDecoder { sharedDecoder }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.contentType(multipartFormData.contentTypeHeader))
        return defaultHeaders
    }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }
}

extension APIDefinition where Parameter == EmptyParameter {
    public var parameters: Parameter? { nil }
}

public extension APIDefinition {
    var contentType: ContentType { .json }

    var decoder: JSONDecoder { sharedDecoder }

    var headers: HTTPHeaders {
        var defaultHeaders = HTTPHeaders.default
        defaultHeaders.add(.contentType("\(contentType.rawValue); charset=UTF-8"))
        return defaultHeaders
    }

    var logger: NetworkLogger { DefaultNetworkLogger() }

    var requestInterceptors: [RequestInterceptor] { [] }

    var responseInterceptors: [ResponseInterceptor] { [] }
}
