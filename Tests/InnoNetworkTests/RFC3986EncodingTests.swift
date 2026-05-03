import Foundation
import Testing
@testable import InnoNetwork

@Suite("RFC 3986 §2.3 unreserved-set encoding")
struct RFC3986EncodingTests {
    @Test("Unreserved characters pass through verbatim")
    func unreservedPassthrough() {
        let alphaNum = "ABCxyz0189"
        let punct = "-._~"
        #expect(RFC3986Encoding.encode(alphaNum) == alphaNum)
        #expect(RFC3986Encoding.encode(punct) == punct)
    }

    @Test("Reserved and gen-delims are percent-encoded")
    func reservedEscaped() {
        #expect(RFC3986Encoding.encode("a+b") == "a%2Bb")
        #expect(RFC3986Encoding.encode("a b") == "a%20b")
        #expect(RFC3986Encoding.encode("a/b?c=d") == "a%2Fb%3Fc%3Dd")
        #expect(RFC3986Encoding.encode("a&b=c") == "a%26b%3Dc")
    }

    @Test("Tilde is preserved (PKCE round-trip safety)")
    func tildePreserved() {
        #expect(RFC3986Encoding.encode("ab~cd") == "ab~cd")
    }

    @Test("PKCE code_verifier (RFC 7636) round-trips byte-for-byte")
    func pkceVerifierRoundTrip() {
        // RFC 7636 §4.1 alphabet: A-Z / a-z / 0-9 / "-" / "." / "_" / "~"
        let verifier = "M25iVXpKU3puUjFaYWg3T1NDTDQtcW1ROUY5YXlwalNoc0hhakxiOGNoYg~~"
        let encoded = RFC3986Encoding.encode(verifier)
        #expect(encoded == verifier)
    }

    @Test("UTF-8 multibyte sequences emit uppercase hex octets")
    func utf8MultiByte() {
        // 한 = 0xED 0x95 0x9C
        #expect(RFC3986Encoding.encode("한") == "%ED%95%9C")
    }

    @Test("Form encoding remains separate from RFC 3986 (space → +, ~ → %7E)")
    func formEncodingIsDistinct() {
        #expect(URLQueryEncoder.formEscape("a b") == "a+b")
        #expect(URLQueryEncoder.formEscape("a+b") == "a%2Bb")
        // RFC 1866 form encoding escapes ~ (only `*-._` are unescaped);
        // RFC 3986 leaves ~ literal — this is the round-trip-safety divergence
        // that breaks PKCE if you reuse the form encoder for OAuth artifacts.
        #expect(URLQueryEncoder.formEscape("a~b") == "a%7Eb")
        #expect(RFC3986Encoding.encode("a~b") == "a~b")
    }
}
