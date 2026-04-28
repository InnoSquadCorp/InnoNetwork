import Foundation

package enum RequestEncodingPolicy: Sendable {
    case none
    case query(URLQueryEncoder, rootKey: String?)
    case json(JSONEncoder)
    case formURLEncoded(URLQueryEncoder, rootKey: String?)
}
