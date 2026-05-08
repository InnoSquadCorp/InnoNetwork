import Foundation
import Testing

@testable import InnoNetwork

@Suite("HTTPHeaderName phantom typing")
struct HTTPHeaderNamePhantomTests {
    @Test("Single-value subscript replaces an existing header rather than appending")
    func singleValueSubscriptReplaces() {
        var headers = HTTPHeaders()
        headers[.authorization] = "Bearer first"
        headers[.authorization] = "Bearer second"

        #expect(headers.values(for: "Authorization") == ["Bearer second"])
    }

    @Test("Single-value subscript getter returns the canonical value")
    func singleValueSubscriptGetterReturnsValue() {
        var headers = HTTPHeaders()
        headers[.contentType] = "application/json"

        #expect(headers[.contentType] == "application/json")
        #expect(headers[.userAgent] == nil)
    }

    @Test("Single-value subscript with nil removes the header")
    func singleValueSubscriptNilRemoves() {
        var headers = HTTPHeaders()
        headers[.host] = "api.example.com"
        headers[.host] = nil

        #expect(headers[.host] == nil)
        #expect(headers.values(for: "Host").isEmpty)
    }

    @Test("Repeatable append accumulates values")
    func repeatableAppendAccumulates() {
        var headers = HTTPHeaders()
        headers.append(.setCookie, value: "session=abc")
        headers.append(.setCookie, value: "tracking=xyz")

        let values = headers.values(for: .setCookie)
        #expect(values == ["session=abc", "tracking=xyz"])
    }

    @Test("Phantom-typed remove drops every matching entry")
    func phantomRemoveDropsAllMatching() {
        var headers = HTTPHeaders()
        headers.append(.setCookie, value: "a")
        headers.append(.setCookie, value: "b")
        headers.remove(HTTPHeaderName<RepeatableHeader>.setCookie)

        #expect(headers.values(for: .setCookie).isEmpty)
    }
}
