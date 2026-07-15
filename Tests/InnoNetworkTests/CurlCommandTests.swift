import Foundation
import Testing

@testable import InnoNetwork

@Suite("Curl Command Tests")
struct CurlCommandTests {
    @Test("curlCommand redacts sensitive headers by default")
    func curlCommandRedactsSensitiveHeadersByDefault() {
        var request = URLRequest(url: URL(string: "https://api.example.com/orders")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("abc-123", forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"name":"coffee"}"#.utf8)

        let command = request.curlCommand()

        #expect(command.contains("curl -X 'POST'"))
        #expect(command.contains("Authorization: <redacted>"))
        #expect(command.contains("Idempotency-Key: <redacted>"))
        #expect(command.contains("Content-Type: application/json"))
        #expect(!command.contains("--data-raw"))
        #expect(!command.contains("coffee"))
        #expect(command.contains("'https://api.example.com/orders'"))
        #expect(!command.contains("Bearer secret"))
        #expect(!command.contains("abc-123"))
    }

    @Test("curlCommand can render file-backed bodies")
    func curlCommandCanRenderFileBackedBodies() {
        var request = URLRequest(url: URL(string: "https://api.example.com/upload")!)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let bodyURL = URL(fileURLWithPath: "/tmp/payload.bin")

        let command = request.curlCommand(
            options: CurlCommandOptions(includesBody: true, bodyFileURL: bodyURL)
        )

        #expect(command.contains("--data-binary '@/tmp/payload.bin'"))
    }

    @Test("curlCommand strips URL credentials and fragment and redacts query values by default")
    func curlCommandRedactsURLMetadataByDefault() throws {
        let url = try #require(
            URL(string: "https://user:password@api.example.com/orders/42?token=secret&flag#access_token=fragment")
        )
        let command = URLRequest(url: url).curlCommand()

        #expect(command.contains("api.example.com/orders/42"))
        #expect(command.contains("token=%3Credacted%3E"))
        #expect(command.contains("flag"))
        #expect(!command.contains("user"))
        #expect(!command.contains("password"))
        #expect(!command.contains("secret"))
        #expect(!command.contains("fragment"))
    }

    @Test("curlCommand exposes query values and body only through explicit opt-ins")
    func curlCommandExplicitSensitiveDataOptIns() throws {
        let url = try #require(
            URL(string: "https://user:password@api.example.com/orders?token=local-debug#fragment")
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"name":"coffee"}"#.utf8)

        let command = request.curlCommand(
            options: CurlCommandOptions(includesBody: true, includesQueryValues: true)
        )

        #expect(command.contains("token=local-debug"))
        #expect(command.contains(#"--data-raw '{"name":"coffee"}'"#))
        #expect(!command.contains("user:password"))
        #expect(!command.contains("fragment"))
    }

    @Test("curlCommand preserves reserved percent escapes while redacting query values")
    func curlCommandPreservesPercentEncodedPath() throws {
        let url = try #require(
            URL(string: "https://api.example.com/files/a%2Fb?token=secret")
        )

        let command = URLRequest(url: url).curlCommand()

        #expect(command.contains("/files/a%2Fb"))
        #expect(!command.contains("/files/a/b"))
        #expect(command.contains("token=%3Credacted%3E"))
        #expect(!command.contains("secret"))
    }
}
