import Foundation


public protocol APIConfigure: Sendable {
    var host: String { get }
    var basePath: String { get }
    var baseURL: URL? { get }
}

extension APIConfigure {
    public var baseURL: URL? {
        URL(string: "\(host)/\(basePath)")
    }
}
