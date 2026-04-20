import Foundation


public struct URLQueryCustomKeyTransform: Sendable {
    let transform: @Sendable ([CodingKey]) -> String

    public init(_ transform: @escaping @Sendable ([CodingKey]) -> String) {
        self.transform = transform
    }
}

public enum URLQueryKeyEncodingStrategy: Sendable {
    case useDefaultKeys
    case convertToSnakeCase
    case custom(URLQueryCustomKeyTransform)

    init(_ strategy: JSONEncoder.KeyEncodingStrategy) {
        switch strategy {
        case .useDefaultKeys:
            self = .useDefaultKeys
        case .convertToSnakeCase:
            self = .convertToSnakeCase
        case .custom(let transform):
            self = .custom(URLQueryCustomKeyTransform { codingPath in
                transform(codingPath).stringValue
            })
        @unknown default:
            self = .useDefaultKeys
        }
    }
}
