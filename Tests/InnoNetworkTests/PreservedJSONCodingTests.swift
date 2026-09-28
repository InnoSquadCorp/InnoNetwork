import Foundation
import Testing

@testable import InnoNetwork

@Suite("Preserved JSON Codable bridge")
struct PreservedJSONCodingTests {
    struct Envelope: Codable, Equatable {
        let name: String
        let values: [PreservedJSON?]
        let metadata: [String: PreservedJSON]
    }

    @Test("Nested objects and arrays preserve unknown fields and arbitrary number tokens")
    func nested() throws {
        let raw = #"{"known":1,"unknown":123456789012345678901234567890123456789012345678901234567890.000e9999}"#
        let data = Data(
            (#"{"name":"hello","values":["# + raw + #",null],"metadata":{"a":[-0.0,1e-9999999999999]}}"#).utf8)
        let decoded = try PreservedJSONCoding.decode(Envelope.self, from: data)
        #expect(decoded.values[0]?.data == Data(raw.utf8))
        #expect(decoded.values[1] == nil)
        let encoded = try PreservedJSONCoding.encode(decoded)
        #expect(encoded.range(of: Data(raw.utf8)) != nil)
        #expect(try PreservedJSONCoding.decode(Envelope.self, from: encoded) == decoded)
    }

    @Test("Foundation codecs refuse preserved values rather than silently round")
    func unsupportedCoders() throws {
        let document = try PreservedJSON(data: Data("1.000000000000000000000000000000000000000000001".utf8))
        #expect(throws: JSONProcessingError.unsupportedCoder) { try JSONEncoder().encode(document) }
        #expect(throws: JSONProcessingError.unsupportedCoder) {
            try JSONDecoder().decode(PreservedJSON.self, from: document.data)
        }
        #expect(try PreservedJSONCoding.encode(document) == document.data)
        let padded = Data("discard 1.00 \n".utf8).dropFirst(7)
        let decoded = try PreservedJSONCoding.decode(PreservedJSON.self, from: padded)
        #expect(decoded.data == Data(" 1.00 \n".utf8))
        #expect(decoded.data.startIndex == 0)
    }

    @Test("Ordinary scalar, optional and Foundation model controls remain Codable")
    func controls() throws {
        struct Model: Codable, Equatable {
            let integer: Int64
            let unsigned: UInt64
            let fraction: Double
            let truth: Bool
            let text: String
            let missing: String?
            let bytes: Data
            let date: Date
            let url: URL
            let decimal: Decimal
        }
        let model = Model(
            integer: .min, unsigned: .max, fraction: 0.25, truth: true, text: "a\n😀",
            missing: nil, bytes: Data([0, 255]), date: Date(timeIntervalSinceReferenceDate: 42),
            url: URL(string: "https://example.com/path")!, decimal: Decimal(string: "123.456")!)
        let encoded = try PreservedJSONCoding.encode(model)
        #expect(try defaultResponseDecoder.decode(Model.self, from: encoded) == model)
        #expect(try PreservedJSONCoding.decode(Model.self, from: defaultRequestEncoder.encode(model)) == model)
        #expect(try PreservedJSONCoding.decode(Int.self, from: Data("1.0".utf8)) == 1)
        #expect(throws: (any Error).self) { try PreservedJSONCoding.encode(Double.infinity) }
        #expect(throws: (any Error).self) { try PreservedJSONCoding.decode(Bool.self, from: Data("1".utf8)) }
    }

    @Test("Nested containers, super coders and coding paths work")
    func containers() throws {
        struct Manual: Codable {
            enum Key: String, CodingKey { case field }
            let value: Int
            init(value: Int) { self.value = value }
            init(from decoder: any Decoder) throws {
                let outer = try decoder.container(keyedBy: Key.self)
                var array = try outer.nestedUnkeyedContainer(forKey: .field)
                let object = try array.nestedContainer(keyedBy: Key.self)
                value = try Int(from: object.superDecoder(forKey: .field))
            }
            func encode(to encoder: any Encoder) throws {
                var outer = encoder.container(keyedBy: Key.self)
                var array = outer.nestedUnkeyedContainer(forKey: .field)
                var object = array.nestedContainer(keyedBy: Key.self)
                try value.encode(to: object.superEncoder(forKey: .field))
            }
        }
        #expect(
            try PreservedJSONCoding.decode(Manual.self, from: PreservedJSONCoding.encode(Manual(value: 3))).value == 3)
    }

    @Test("Encoding/decoding resource limits include nested raw values and malformed custom Codable")
    func limits() throws {
        let raw = try PreservedJSON(data: Data("[[[1]]]".utf8))
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.encode([raw], limits: .init(maximumDepth: 4))
        }
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.encode(["large"], limits: .init(maximumBytes: 3))
        }
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.decode(
                [Int].self, from: Data("[1,2]".utf8), limits: .init(maximumValidationWork: 1))
        }
        struct Recursive: Codable {
            init() {}
            init(from decoder: any Decoder) throws { _ = try decoder.singleValueContainer().decode(Recursive.self) }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(self)
            }
        }
        // A malicious implementation calling itself directly is application-owned;
        // recursive use of this codec's containers is bounded by shared work limits.
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.decode(
                Recursive.self, from: Data("1".utf8), limits: .init(maximumValidationWork: 20))
        }
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.encode(Recursive(), limits: .init(maximumValidationWork: 20))
        }
        struct Empty: Encodable { func encode(to encoder: any Encoder) throws {} }
        #expect(throws: JSONProcessingError.invalidJSON) { try PreservedJSONCoding.encode(Empty()) }
    }

    @Test("Wide arrays use bounded, linear container accumulation")
    func wideArray() throws {
        let values = Array(0..<10_000)
        let encoded = try PreservedJSONCoding.encode(values)
        #expect(try PreservedJSONCoding.decode([Int].self, from: encoded) == values)
    }

    @Test("Custom response decoding failures retain response context and cancellation semantics")
    func customDecodeBoundary() throws {
        let response = Response(
            statusCode: 200, data: Data("{}".utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        let invalid = TransportPolicy<Int>.custom(encoding: .none) { _, _ in
            throw JSONProcessingError.noMatchingSchema
        }
        do {
            _ = try invalid.responseDecoder.decode(data: response.data, response: response)
            Issue.record("Validation failure was accepted")
        } catch NetworkError.decoding(let stage, _, let context) {
            #expect(stage == .responseBody)
            #expect(context == response)
        }
        if case .custom(let decode) = invalid.responseDecoding {
            #expect(throws: NetworkError.self) { try decode(response.data, response) }
        } else {
            Issue.record("Lost custom decoding strategy")
        }
        let canceled = TransportPolicy<Int>.custom(encoding: .none) { _, _ in throw CancellationError() }
        #expect(throws: CancellationError.self) {
            try canceled.responseDecoder.decode(data: Data(), response: response)
        }
        let explicit = TransportPolicy<Int>.custom(encoding: .none) { _, _ in
            throw NetworkError.configuration(reason: .invalidRequest("fixture"))
        }
        do {
            _ = try explicit.responseDecoder.decode(data: Data(), response: response)
            Issue.record("Explicit network error was accepted")
        } catch NetworkError.configuration {}
    }

    @Test("Failed unkeyed decoding leaves the same element available for a typed fallback")
    func unkeyedFallback() throws {
        struct View: Decodable {
            let text: String
            let number: Int
            enum Key: String, CodingKey { case value }
            init(from decoder: any Decoder) throws {
                var container = try decoder.unkeyedContainer()
                #expect((try? container.decode(Int.self)) == nil)
                #expect(container.currentIndex == 0)
                text = try container.decode(String.self)
                #expect((try? container.nestedUnkeyedContainer()) == nil)
                #expect(container.currentIndex == 1)
                number = try container.nestedContainer(keyedBy: Key.self).decode(Int.self, forKey: .value)
                #expect(container.isAtEnd)
            }
        }
        let data = Data(#"["hello",{"value":42}]"#.utf8)
        let control = try JSONDecoder().decode(View.self, from: data)
        let result = try PreservedJSONCoding.decode(View.self, from: data)
        #expect(result.text == control.text && result.number == control.number)
    }

    @Test("Repeated keyed nested containers share accumulated fields and array elements")
    func repeatedNestedContainers() throws {
        struct View: Encodable {
            enum Key: String, CodingKey { case object, array, first, second }
            func encode(to encoder: any Encoder) throws {
                var root = encoder.container(keyedBy: Key.self)
                var first = root.nestedContainer(keyedBy: Key.self, forKey: .object)
                try first.encode(1, forKey: .first)
                var second = root.nestedContainer(keyedBy: Key.self, forKey: .object)
                try second.encode(2, forKey: .second)
                var array = root.nestedUnkeyedContainer(forKey: .array)
                try array.encode("first")
                var again = root.nestedUnkeyedContainer(forKey: .array)
                #expect(again.count == 1)
                try again.encode("second")
            }
        }
        struct Result: Decodable, Equatable {
            struct Members: Decodable, Equatable {
                let first: Int
                let second: Int
            }
            let object: Members
            let array: [String]
        }
        let control = try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(View()))
        let result = try JSONDecoder().decode(Result.self, from: PreservedJSONCoding.encode(View()))
        #expect(result == control)
    }
}
