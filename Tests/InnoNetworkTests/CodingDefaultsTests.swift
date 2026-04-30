import Foundation
import Testing

@testable import InnoNetwork

@Suite("Coding Defaults Tests")
struct CodingDefaultsTests {

    @Test("defaultDateFormatter is the same instance on every access")
    func sharedDateFormatterIdentity() {
        let first = defaultDateFormatter
        let second = defaultDateFormatter
        #expect(first === second)
    }

    @Test("Default request and response coders share the canonical date formatter")
    func encoderDecoderShareCanonicalFormatter() throws {
        let encoder = makeDefaultRequestEncoder()
        let decoder = makeDefaultResponseDecoder()
        guard
            case .formatted(let encoderFormatter) = encoder.dateEncodingStrategy,
            case .formatted(let decoderFormatter) = decoder.dateDecodingStrategy
        else {
            Issue.record("Default coders should use a formatted date strategy")
            return
        }
        #expect(encoderFormatter === defaultDateFormatter)
        #expect(decoderFormatter === defaultDateFormatter)
    }

    @Test("URLQueryEncoder default init reuses the canonical date formatter")
    func urlQueryEncoderDefaultInitReusesFormatter() {
        let encoder = URLQueryEncoder()
        guard case .formatted(let formatter) = encoder.dateEncodingStrategy else {
            Issue.record("URLQueryEncoder default should use a formatted date strategy")
            return
        }
        #expect(formatter === defaultDateFormatter)
    }

    @Test("Round-trip encode/decode of a Date matches the canonical format")
    func roundTripEncodeDecodeDate() throws {
        struct Body: Codable, Equatable {
            let when: Date
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let body = Body(when: date)
        let encoder = makeDefaultRequestEncoder()
        let decoder = makeDefaultResponseDecoder()
        let payload = try encoder.encode(body)
        let decoded = try decoder.decode(Body.self, from: payload)
        // Equality on Date hits sub-second precision; the canonical formatter
        // serializes milliseconds so a round trip preserves the value.
        #expect(decoded == body)
    }
}
