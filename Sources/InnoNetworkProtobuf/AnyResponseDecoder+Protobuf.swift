import Foundation
import InnoNetwork
import SwiftProtobuf


extension AnyResponseDecoder where Output: SwiftProtobuf.Message & Sendable {
    init(strategy: ResponseDecodingStrategy<Output>) {
        switch strategy {
        case .protobuf:
            self = .protobuf()
        case .protobufAllowingEmpty where Output.self is any HTTPEmptyResponseMessage.Type:
            self = .init { data, response in
                if data.isEmpty || response.statusCode == 204,
                   let emptyType = Output.self as? any HTTPEmptyResponseMessage.Type,
                   let emptyValue = emptyType.emptyResponseValue() as? Output {
                    return emptyValue
                }

                do {
                    return try Output(serializedBytes: data)
                } catch {
                    throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
                }
            }
        case .custom(let closure):
            self = .init(closure)
        default:
            self = .protobuf()
        }
    }
}

public extension AnyResponseDecoder where Output: SwiftProtobuf.Message {
    static func protobuf() -> Self {
        Self { data, response in
            do {
                return try Output(serializedBytes: data)
            } catch {
                throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
            }
        }
    }
}

public extension AnyResponseDecoder where Output: SwiftProtobuf.Message & HTTPEmptyResponseMessage {
    static func protobufEmptyCapable() -> Self {
        Self { data, response in
            if data.isEmpty || response.statusCode == 204 {
                return Output.emptyResponseValue()
            }

            do {
                return try Output(serializedBytes: data)
            } catch {
                throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
            }
        }
    }
}
