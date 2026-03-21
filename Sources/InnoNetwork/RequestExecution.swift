import Foundation


package enum RequestPayload: Sendable {
    case none
    case data(Data)
    case queryItems([URLQueryItem])
}

package protocol SingleRequestExecutable: Sendable {
    associatedtype APIResponse: Sendable

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
    var method: HTTPMethod { get }
    var path: String { get }
    var headers: HTTPHeaders { get }

    func makePayload() throws -> RequestPayload
    func decode(data: Data, response: Response) throws -> APIResponse
}

package struct APISingleRequestExecutable<Base: APIDefinition>: SingleRequestExecutable {
    let base: Base

    package var logger: NetworkLogger { base.logger }
    package var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    package var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }
    package var method: HTTPMethod { base.method }
    package var path: String { base.path }
    package var headers: HTTPHeaders { base.headers }

    package func makePayload() throws -> RequestPayload {
        guard let parameters = base.parameters else { return .none }
        let transportPolicy = base.transportPolicy

        switch transportPolicy.requestEncoding {
        case .none:
            return .none
        case .query:
            return .queryItems(try encodeQueryItems(parameters))
        case .json(let encoder):
            return .data(try encoder.encode(parameters))
        case .formURLEncoded:
            return .data(try encodeForm(parameters))
        case .protobuf:
            return .none
        }
    }

    package func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.transportPolicy.responseDecoder.decode(data: data, response: response)
    }

    private func encodeQueryItems(_ parameters: Base.Parameter) throws -> [URLQueryItem] {
        do {
            switch base.transportPolicy.requestEncoding {
            case .query(let encoder, let rootKey), .formURLEncoded(let encoder, let rootKey):
                return try encoder.encode(parameters, rootKey: rootKey)
            default:
                return try base.queryEncoder.encode(parameters, rootKey: base.queryRootKey)
            }
        } catch URLQueryEncoder.EncodingError.unsupportedTopLevelValue {
            throw NetworkError.invalidRequestConfiguration(
                "Top-level scalar or array query parameters require queryRootKey to be set."
            )
        }
    }

    private func encodeForm(_ parameters: Base.Parameter) throws -> Data {
        do {
            switch base.transportPolicy.requestEncoding {
            case .formURLEncoded(let encoder, let rootKey):
                return try encoder.encodeForm(parameters, rootKey: rootKey)
            case .query(let encoder, let rootKey):
                return try encoder.encodeForm(parameters, rootKey: rootKey)
            default:
                return try base.queryEncoder.encodeForm(parameters, rootKey: base.queryRootKey)
            }
        } catch URLQueryEncoder.EncodingError.unsupportedTopLevelValue {
            throw NetworkError.invalidRequestConfiguration(
                "Top-level scalar or array form parameters require queryRootKey to be set."
            )
        }
    }
}

package struct MultipartSingleRequestExecutable<Base: MultipartAPIDefinition>: SingleRequestExecutable {
    let base: Base

    package var logger: NetworkLogger { base.logger }
    package var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    package var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }
    package var method: HTTPMethod { base.method }
    package var path: String { base.path }
    package var headers: HTTPHeaders { base.headers }

    package func makePayload() throws -> RequestPayload {
        .data(base.multipartFormData.encode())
    }

    package func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.transportPolicy.responseDecoder.decode(data: data, response: response)
    }
}
