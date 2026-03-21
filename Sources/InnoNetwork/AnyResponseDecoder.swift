import Foundation


public struct AnyResponseDecoder<Output: Sendable>: Sendable {
    private let decodeClosure: @Sendable (Data, Response) throws -> Output

    public init(_ decode: @escaping @Sendable (Data, Response) throws -> Output) {
        self.decodeClosure = decode
    }

    public func decode(data: Data, response: Response) throws -> Output {
        try decodeClosure(data, response)
    }
}

extension AnyResponseDecoder where Output: Decodable & Sendable {
    init(strategy: ResponseDecodingStrategy<Output>) {
        switch strategy {
        case .json(let decoder):
            self = .json(decoder: decoder)
        case .jsonAllowingEmpty(let decoder) where Output.self is any HTTPEmptyResponseDecodable.Type:
            self = .init { data, response in
                if data.isEmpty || response.statusCode == 204,
                   let emptyType = Output.self as? any HTTPEmptyResponseDecodable.Type,
                   let emptyValue = emptyType.emptyResponseValue() as? Output {
                    return emptyValue
                }

                do {
                    return try decoder.decode(Output.self, from: data)
                } catch {
                    throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
                }
            }
        case .custom(let closure):
            self = .init(closure)
        default:
            self = .json(decoder: JSONDecoder())
        }
    }
}

public extension AnyResponseDecoder where Output: Decodable {
    static func json(decoder: JSONDecoder) -> Self {
        Self { data, response in
            do {
                return try decoder.decode(Output.self, from: data)
            } catch {
                throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
            }
        }
    }
}

public extension AnyResponseDecoder where Output: Decodable & HTTPEmptyResponseDecodable {
    static func jsonEmptyCapable(decoder: JSONDecoder) -> Self {
        Self { data, response in
            if data.isEmpty || response.statusCode == 204 {
                return Output.emptyResponseValue()
            }

            do {
                return try decoder.decode(Output.self, from: data)
            } catch {
                throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
            }
        }
    }
}
