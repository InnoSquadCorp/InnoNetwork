import Foundation
import InnoNetwork
import SwiftProtobuf


package struct ProtobufSingleRequestExecutable<Base: ProtobufAPIDefinition>: SingleRequestExecutable {
    let base: Base

    package var logger: NetworkLogger { base.logger }
    package var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    package var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }
    package var method: HTTPMethod { base.method }
    package var path: String { base.path }
    package var headers: HTTPHeaders { base.headers }

    package func makePayload() throws -> RequestPayload {
        if case .get = method {
            if base.parameters != nil {
                throw NetworkError.invalidRequestConfiguration(
                    "GET requests with protobuf parameters are not supported. " +
                    "Protobuf messages cannot be serialized to URL query parameters. " +
                    "Use POST/PUT methods for requests with protobuf body, or set parameters to nil for GET requests."
                )
            }
            return .none
        }

        guard let parameters = base.parameters else { return .none }
        switch base.transportPolicy.requestEncoding {
        case .protobuf:
            return .data(try parameters.serializedData())
        case .none, .query, .json, .formURLEncoded:
            return .data(try parameters.serializedData())
        }
    }

    package func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.transportPolicy.responseDecoder.decode(data: data, response: response)
    }
}
