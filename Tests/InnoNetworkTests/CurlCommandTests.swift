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
        #expect(command.contains(#"--data-raw '{"name":"coffee"}'"#))
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

        let command = request.curlCommand(options: CurlCommandOptions(bodyFileURL: bodyURL))

        #expect(command.contains("--data-binary '@/tmp/payload.bin'"))
    }
}
