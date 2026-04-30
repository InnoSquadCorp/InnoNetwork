import Foundation
import Testing

@testable import InnoNetwork

private func expectCanonicalFormatterConfiguration(_ formatter: DateFormatter) {
    let canonical = makeDefaultDateFormatter()
    #expect(formatter.dateFormat == canonical.dateFormat)
    #expect(formatter.locale.identifier == canonical.locale.identifier)
    #expect(formatter.timeZone == canonical.timeZone)
}


@Suite("Coding Defaults Tests")
struct CodingDefaultsTests {

    @Test("defaultDateFormatter returns a fresh canonical instance on every access")
    func defaultDateFormatterReturnsFreshCanonicalInstance() async {
        let first = defaultDateFormatter
        let second = defaultDateFormatter
        #expect(first !== second)
        expectCanonicalFormatterConfiguration(first)
        expectCanonicalFormatterConfiguration(second)
    }

    @Test("Default request and response coders use fresh canonical date formatters")
    func encoderDecoderUseFreshCanonicalFormatters() async throws {
        let encoder = makeDefaultRequestEncoder()
        let decoder = makeDefaultResponseDecoder()
        guard
            case .formatted(let encoderFormatter) = encoder.dateEncodingStrategy,
            case .formatted(let decoderFormatter) = decoder.dateDecodingStrategy
        else {
            Issue.record("Default coders should use a formatted date strategy")
            return
        }
        #expect(encoderFormatter !== decoderFormatter)
        expectCanonicalFormatterConfiguration(encoderFormatter)
        expectCanonicalFormatterConfiguration(decoderFormatter)
    }

    @Test("Default coder accessors return fresh mutable instances")
    func defaultCoderAccessorsReturnFreshMutableInstances() async {
        let firstEncoder = defaultRequestEncoder
        firstEncoder.dateEncodingStrategy = .secondsSince1970
        let secondEncoder = defaultRequestEncoder
        #expect(firstEncoder !== secondEncoder)
        if case .formatted = secondEncoder.dateEncodingStrategy {
            // expected
        } else {
            Issue.record("Mutation of one defaultRequestEncoder instance should not leak to the next access")
        }

        let firstDecoder = defaultResponseDecoder
        firstDecoder.dateDecodingStrategy = .secondsSince1970
        let secondDecoder = defaultResponseDecoder
        #expect(firstDecoder !== secondDecoder)
        if case .formatted = secondDecoder.dateDecodingStrategy {
            // expected
        } else {
            Issue.record("Mutation of one defaultResponseDecoder instance should not leak to the next access")
        }
    }

    @Test("URLQueryEncoder default init reuses the canonical date formatter")
    func urlQueryEncoderDefaultInitUsesCanonicalFormatter() async {
        let encoder = URLQueryEncoder()
        guard case .formatted(let formatter) = encoder.dateEncodingStrategy else {
            Issue.record("URLQueryEncoder default should use a formatted date strategy")
            return
        }
        expectCanonicalFormatterConfiguration(formatter)
    }

    @Test("Round-trip encode/decode of a Date matches the canonical format")
    func roundTripEncodeDecodeDate() async throws {
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
