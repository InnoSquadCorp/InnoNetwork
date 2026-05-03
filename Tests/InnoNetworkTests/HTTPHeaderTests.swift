import Foundation
import Testing

@testable import InnoNetwork

@Suite("HTTPHeader multi-value semantics")
struct HTTPHeaderTests {

    @Test("add() preserves repeated entries, update() collapses them")
    func addPreservesAndUpdateCollapses() async {
        var headers = HTTPHeaders()
        headers.add(name: "Set-Cookie", value: "a=1")
        headers.add(name: "set-cookie", value: "b=2")
        headers.add(name: "SET-COOKIE", value: "c=3")

        #expect(headers.values(for: "Set-Cookie") == ["a=1", "b=2", "c=3"])
        #expect(headers.count == 3)

        headers.update(name: "Set-Cookie", value: "single=z")

        #expect(headers.values(for: "Set-Cookie") == ["single=z"])
        #expect(headers.count == 1)
    }

    @Test("update() preserves the position of the first matching entry")
    func updatePreservesFirstPosition() async {
        var headers = HTTPHeaders()
        headers.add(name: "X-A", value: "1")
        headers.add(name: "X-Multi", value: "first")
        headers.add(name: "X-B", value: "2")
        headers.add(name: "x-multi", value: "second")

        headers.update(name: "X-Multi", value: "merged")

        let names = headers.map(\.name)
        #expect(names == ["X-A", "X-Multi", "X-B"])
        #expect(headers.values(for: "X-Multi") == ["merged"])
    }

    @Test("value(for:) returns the comma-joined RFC 7230 representation")
    func valueReturnsRFC7230Join() async {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/html")
        headers.add(name: "accept", value: "application/json")

        #expect(headers.value(for: "Accept") == "text/html, application/json")
        #expect(headers.values(for: "Accept") == ["text/html", "application/json"])
    }

    @Test("dictionary collapses duplicates while keeping first canonical name")
    func dictionaryCollapsesDuplicates() async {
        var headers = HTTPHeaders()
        headers.add(name: "X-Accept", value: "text/html")
        headers.add(name: "X-Trace", value: "abc")
        headers.add(name: "x-accept", value: "application/json")

        let dict = headers.dictionary

        #expect(dict.keys.contains("X-Accept"))
        #expect(dict.keys.contains("x-accept") == false)
        #expect(dict["X-Accept"] == "text/html, application/json")
        #expect(dict["X-Trace"] == "abc")
    }

    @Test("remove() drops every case-insensitive match")
    func removeDropsAllMatches() async {
        var headers = HTTPHeaders()
        headers.add(name: "X-Trace", value: "1")
        headers.add(name: "X-OTHER", value: "y")
        headers.add(name: "x-trace", value: "2")

        headers.remove(name: "X-Trace")

        #expect(headers.values(for: "X-Trace").isEmpty)
        #expect(headers.count == 1)
        #expect(headers.first?.name == "X-OTHER")
    }

    @Test("init([HTTPHeader]) preserves multi-value entries verbatim")
    func arrayInitPreservesMultiValue() async {
        let headers = HTTPHeaders([
            HTTPHeader(name: "Set-Cookie", value: "a=1"),
            HTTPHeader(name: "Set-Cookie", value: "b=2"),
        ])

        #expect(headers.values(for: "Set-Cookie") == ["a=1", "b=2"])
    }

    @Test("URLRequest.headers setter preserves multi-value list-rule headers")
    func urlRequestHeadersPreservesMultiValue() async {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/html")
        headers.add(name: "Accept", value: "application/json")
        headers.add(name: "Link", value: "<https://a>; rel=next")
        headers.add(name: "Link", value: "<https://b>; rel=last")

        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.headers = headers

        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html,application/json")
        #expect(request.value(forHTTPHeaderField: "Link") == "<https://a>; rel=next,<https://b>; rel=last")
    }

    @Test("URLRequest.headers setter collapses single-value Authorization to last value")
    func urlRequestHeadersSingleValueCollapses() async {
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer stale")
        headers.add(name: "authorization", value: "Bearer fresh")

        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.headers = headers

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test("URLRequest.headers setter clears prior headers before applying new set")
    func urlRequestHeadersClearsExisting() async {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.setValue("legacy", forHTTPHeaderField: "X-Legacy")
        request.setValue("old", forHTTPHeaderField: "Authorization")

        var fresh = HTTPHeaders()
        fresh.add(name: "Authorization", value: "Bearer new")
        request.headers = fresh

        #expect(request.value(forHTTPHeaderField: "X-Legacy") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("URLSessionConfiguration.headers applies request single-value semantics")
    func configurationHeadersUseLastSingleValue() async {
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer stale")
        headers.add(name: "authorization", value: "Bearer fresh")
        headers.add(name: "Accept", value: "application/json")
        headers.add(name: "accept", value: "text/plain")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.headers = headers

        let configured = configuration.headers
        #expect(configured.value(for: "Authorization") == "Bearer fresh")
        #expect(configured.value(for: "Accept") == "application/json, text/plain")
    }

    @Test("Basic authorization encodes non-ASCII credentials as UTF-8 token68")
    func basicAuthorizationEncodesNonASCIIAsUTF8Token68() {
        let header = HTTPHeader.authorization(username: "test", password: "123\u{00A3}")

        #expect(header.name == "Authorization")
        #expect(header.value == "Basic dGVzdDoxMjPCow==")
        #expect(header.value.contains("charset") == false)
    }

    @Test("Basic authorization normalizes Unicode credentials to NFC")
    func basicAuthorizationNormalizesUnicodeCredentialsToNFC() {
        let decomposedAccent = "e\u{0301}"
        let header = HTTPHeader.authorization(username: "user", password: decomposedAccent)

        #expect(header.value == "Basic dXNlcjrDqQ==")
    }

    @Test("qualityEncoded omits q=1 and strips insignificant zeros")
    func qualityEncodedFormatsQValues() {
        let encoded = ["br", "gzip", "deflate"].qualityEncoded()

        #expect(encoded == "br, gzip;q=0.9, deflate;q=0.8")
    }

    @Test("qualityEncoded clamps long lists at zero")
    func qualityEncodedClampsLongListsAtZero() {
        let encoded = (0..<12).map { "encoding-\($0)" }.qualityEncoded()

        #expect(encoded.contains("q=-") == false)
        #expect(encoded.hasSuffix("encoding-10;q=0, encoding-11;q=0"))
    }
}


@Suite("MultipartFormData header encoding")
struct MultipartFormDataHeaderTests {

    @Test("ASCII filenames emit the legacy filename parameter only")
    func asciiFilenameEmitsLegacyOnly() async throws {
        var form = MultipartFormData(boundary: "TestBoundary")
        form.append(Data("hello".utf8), name: "file", fileName: "report.txt", mimeType: "text/plain")

        let body = try form.encode()
        let bodyString = String(data: body, encoding: .utf8) ?? ""

        #expect(bodyString.contains("filename=\"report.txt\""))
        #expect(bodyString.contains("filename*=") == false)
    }

    @Test("Non-ASCII filenames emit RFC 5987 filename* alongside ASCII fallback")
    func nonASCIIFilenameEmitsExtendedParameter() async throws {
        var form = MultipartFormData(boundary: "TestBoundary")
        // Korean: 보고서.txt
        form.append(Data("hello".utf8), name: "file", fileName: "보고서.txt", mimeType: "text/plain")

        let body = try form.encode()
        let bodyString = String(data: body, encoding: .utf8) ?? ""

        // ASCII fallback: each non-ASCII scalar becomes "_"
        #expect(bodyString.contains("filename=\"___.txt\""))
        // RFC 5987: 보 = E1 84 87 (Hangul Jamo) NOT — UTF-8 of 보 is 0xEB 0xB3 0xB4
        // Verify presence of the percent-encoded UTF-8 prefix.
        #expect(bodyString.contains("filename*=UTF-8''"))
        #expect(bodyString.contains("%EB%B3%B4"))
        #expect(bodyString.contains(".txt"))
    }

    @Test("Per-part Content-Length is opt-in via includesPartContentLength")
    func contentLengthIsOptIn() async throws {
        var optOut = MultipartFormData(boundary: "B")
        optOut.append(Data("abcdef".utf8), name: "f", fileName: "f.bin", mimeType: "application/octet-stream")
        let withoutHeader = String(data: try optOut.encode(), encoding: .utf8) ?? ""
        #expect(withoutHeader.contains("Content-Length:") == false)

        var optIn = MultipartFormData(boundary: "B", includesPartContentLength: true)
        optIn.append(Data("abcdef".utf8), name: "f", fileName: "f.bin", mimeType: "application/octet-stream")
        let withHeader = String(data: try optIn.encode(), encoding: .utf8) ?? ""
        #expect(withHeader.contains("Content-Length: 6\r\n"))
    }
}
