import Foundation
import InnoNetwork

struct User: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User
    let id: Int
}

@APIDefinition(method: .post, path: "/users", auth: .anonymous)
struct CreateUser {
    struct Body: Encodable, Sendable { let name: String }
    typealias APIResponse = User
    let body: Body
}

// Custom buffered bytes deliberately do not require Codable or a companion codec.
struct BinaryReceipt: Sendable, Equatable {
    let bytes: Data
}

struct UploadBytes: EncodedAPIDefinition {
    typealias APIResponse = BinaryReceipt
    let payload: Data
    var method: HTTPMethod { .post }
    var path: String { "/binary" }
    var sessionAuthentication: SessionAuthentication { .anonymous }

    func makeEncodedRequest() throws(NetworkError) -> EncodedRequest<BinaryReceipt> {
        EncodedRequest(
            method: method, path: path, auth: sessionAuthentication,
            body: .init(contentType: "application/octet-stream", maximumBytes: 1024) {
                payload
            },
            options: .init(maximumResponseBytes: 1024),
            responseDecoder: .init { data, _ in BinaryReceipt(bytes: data) }
        )
    }
}

// JSON forwarding extensions need this explicit bound in 6.1.
extension OperationNetworkClient where Base: NetworkClient {
    func startUser(id: Int) -> NetworkOperation<User> {
        start(GetUser(id: id))
    }
}
