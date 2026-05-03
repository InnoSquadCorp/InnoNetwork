import Foundation
import Testing

@testable import InnoNetwork

@Suite("HTTPListParser — RFC 9110 §5.6 quoted-string aware split")
struct HTTPListParserTests {
    @Test("Plain comma-separated list splits at every comma")
    func plainSplit() {
        let parts = HTTPListParser.split("no-cache, max-age=60, public")
        #expect(parts == ["no-cache", "max-age=60", "public"])
    }

    @Test("Quoted-string commas do not terminate elements")
    func quotedCommaPreserved() {
        let parts = HTTPListParser.split(#"private="set-cookie, x-foo", max-age=60"#)
        #expect(parts.count == 2)
        #expect(parts[0] == #"private="set-cookie, x-foo""#)
        #expect(parts[1] == "max-age=60")
    }

    @Test("Quoted-pair escape preserves trailing quote inside element")
    func quotedPairEscape() {
        let parts = HTTPListParser.split(#"foo="a\",b", bar"#)
        #expect(parts.count == 2)
        #expect(parts[0] == #"foo="a\",b""#)
        #expect(parts[1] == "bar")
    }

    @Test("Empty elements (consecutive commas) are dropped")
    func emptyElementsDropped() {
        let parts = HTTPListParser.split("a,, ,b,")
        #expect(parts == ["a", "b"])
    }

    @Test("directiveName returns lowercased token before =, trimmed")
    func directiveNameLowercased() {
        #expect(HTTPListParser.directiveName(of: "Max-Age=60") == "max-age")
        #expect(HTTPListParser.directiveName(of: "  No-Cache  ") == "no-cache")
        #expect(HTTPListParser.directiveName(of: #"private="x-foo""#) == "private")
    }

    @Test("Cache-Control with quoted private directive recovers all directive names")
    func cacheControlIntegration() {
        let parts = HTTPListParser.split(#"private="x-foo, x-bar", max-age=60, no-store"#)
        let names = Set(parts.map(HTTPListParser.directiveName(of:)))
        #expect(names == ["private", "max-age", "no-store"])
    }
}
