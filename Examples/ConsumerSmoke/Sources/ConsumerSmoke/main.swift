import Foundation
import InnoNetwork
import InnoNetworkProtobuf
import InnoNetworkDownload
import InnoNetworkWebSocket


private struct ConsumerUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct ConsumerRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ConsumerUser

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com")!
    )
)
_ = client
_ = ConsumerRequest()
_ = ProtobufEmptyResponse.self
_ = DownloadConfiguration.safeDefaults(sessionIdentifier: "com.example.consumer.downloads")
_ = WebSocketConfiguration.safeDefaults()

print("ConsumerSmoke OK")
