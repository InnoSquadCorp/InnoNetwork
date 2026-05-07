import Foundation
import InnoNetwork

struct User: Decodable, Sendable {
    let login: String
    let id: Int
    let name: String?
}

struct GetUser {
    let login: String

    init(login: String) {
        self.login = login
    }
}
