import Foundation
import Testing

@testable import InnoNetwork

@Suite("JSON codec retained resources and superclass compatibility")
struct JSONCodecResourceTests {
    final class Counter { var writes = 0 }
    struct Repeated: Encodable {
        let counter: Counter
        let count: Int
        func encode(to encoder: any Encoder) throws {
            var array = encoder.unkeyedContainer()
            for _ in 0..<count {
                counter.writes += 1
                try array.encode(String(repeating: "x", count: 4096))
            }
        }
    }

    @Test func aggregateBuffersStopEarly() throws {
        let counter = Counter()
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.encode(Repeated(counter: counter, count: 1000), limits: .init(maximumBytes: 8192))
        }
        #expect(counter.writes == 2)
        #expect(
            try PreservedJSONCoding.encode(Repeated(counter: Counter(), count: 1), limits: .init(maximumBytes: 8192))
                .count == 4100)
    }

    struct SuperView: Decodable, Equatable {
        enum Key: String, CodingKey { case custom }
        let ordinary: Int?
        let custom: Int?
        let paths: [[String]]
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let ordinaryDecoder = try container.superDecoder()
            let customDecoder = try container.superDecoder(forKey: .custom)
            ordinary = try Int?(from: ordinaryDecoder)
            custom = try Int?(from: customDecoder)
            paths = [ordinaryDecoder.codingPath.map(\.stringValue), customDecoder.codingPath.map(\.stringValue)]
        }
    }

    @Test(arguments: ["{}", #"{"super":null,"custom":null}"#, #"{"super":3,"custom":4}"#])
    func superclassCompatibility(_ json: String) throws {
        let data = Data(json.utf8)
        #expect(
            try PreservedJSONCoding.decode(SuperView.self, from: data)
                == JSONDecoder().decode(SuperView.self, from: data))
    }

    @Test func overwrittenKeysReleaseBuffers() throws {
        struct Overwrites: Encodable {
            enum Key: String, CodingKey { case value }
            func encode(to encoder: any Encoder) throws {
                var root = encoder.container(keyedBy: Key.self)
                for _ in 0..<100 { try root.encode(String(repeating: "x", count: 40), forKey: .value) }
            }
        }
        #expect(try PreservedJSONCoding.encode(Overwrites(), limits: .init(maximumBytes: 54)).count == 52)
    }

    @Test func escapedKeysAndEmptyContainersAreCharged() throws {
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.encode(["\n": "x"], limits: .init(maximumBytes: 9))
        }
        #expect(try PreservedJSONCoding.encode(["\n": "x"], limits: .init(maximumBytes: 10)).count == 10)
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.encode([[], [], []] as [[Int]], limits: .init(maximumBytes: 9))
        }
        #expect(try PreservedJSONCoding.encode([[], [], []] as [[Int]], limits: .init(maximumBytes: 10)).count == 10)
    }

    @Test func retainedDetachedHandleAndCaughtFailureStayBounded() throws {
        struct Held: Encodable {
            enum Key: String, CodingKey { case value }
            func encode(to encoder: any Encoder) throws {
                var root = encoder.container(keyedBy: Key.self)
                let detached = root.superEncoder(forKey: .value)
                var original = detached.singleValueContainer()
                try original.encode(String(repeating: "x", count: 30))
                // Replacing the dictionary entry must not release a live handle's charge.
                #expect(throws: JSONProcessingError.resourceLimit) {
                    try root.encode(String(repeating: "y", count: 30), forKey: .value)
                }
                withExtendedLifetime(detached) {}
            }
        }
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.encode(Held(), limits: .init(maximumBytes: 50))
        }
        #expect(throws: JSONProcessingError.resourceLimit) {
            try PreservedJSONCoding.decode(SuperView.self, from: Data("{}".utf8), limits: .init(maximumDepth: 1))
        }
        #expect(
            try PreservedJSONCoding.decode(SuperView.self, from: Data("{}".utf8), limits: .init(maximumBytes: 2))
                .ordinary == nil)
    }
}
