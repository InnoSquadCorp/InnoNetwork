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

    @Test("defaultDateFormatter returns the shared canonical instance on every access")
    func defaultDateFormatterReturnsSharedCanonicalInstance() async {
        let first = defaultDateFormatter
        let second = defaultDateFormatter
        // The accessor exposes a single immutable instance; consumers never
        // mutate it, so the shared identity is by design.
        #expect(first === second)
        expectCanonicalFormatterConfiguration(first)
    }

    @Test("Default request and response coders use the shared canonical date formatter")
    func encoderDecoderUseSharedCanonicalFormatter() async throws {
        let encoder = makeDefaultRequestEncoder()
        let decoder = makeDefaultResponseDecoder()
        guard
            case .formatted(let encoderFormatter) = encoder.dateEncodingStrategy,
            case .formatted(let decoderFormatter) = decoder.dateDecodingStrategy
        else {
            Issue.record("Default coders should use a formatted date strategy")
            return
        }
        #expect(encoderFormatter === decoderFormatter)
        expectCanonicalFormatterConfiguration(encoderFormatter)
    }

    @Test("makeDefaultRequestEncoder honours an explicit keyEncodingStrategy")
    func encoderHonoursKeyEncodingStrategy() async {
        let encoder = makeDefaultRequestEncoder(keyEncodingStrategy: .convertToSnakeCase)
        if case .convertToSnakeCase = encoder.keyEncodingStrategy {
            // expected
        } else {
            Issue.record("Encoder should reflect the requested key strategy")
        }
        let defaulted = makeDefaultRequestEncoder()
        if case .useDefaultKeys = defaulted.keyEncodingStrategy {
            // expected
        } else {
            Issue.record("Default key strategy must remain useDefaultKeys")
        }
    }

    @Test("makeDefaultResponseDecoder honours an explicit keyDecodingStrategy")
    func decoderHonoursKeyDecodingStrategy() async {
        let decoder = makeDefaultResponseDecoder(keyDecodingStrategy: .convertFromSnakeCase)
        if case .convertFromSnakeCase = decoder.keyDecodingStrategy {
            // expected
        } else {
            Issue.record("Decoder should reflect the requested key strategy")
        }
        let defaulted = makeDefaultResponseDecoder()
        if case .useDefaultKeys = defaulted.keyDecodingStrategy {
            // expected
        } else {
            Issue.record("Default key strategy must remain useDefaultKeys")
        }
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
