import Foundation
import Testing
@testable import InnoNetwork


/// Parametrized property-style tests for `URLQueryEncoder`. The encoder's
/// flattening rules are documented in `docs/QueryEncoding.md`; these tests
/// pin every documented case down with executable expectations so the
/// flattening contract cannot drift silently between releases.
@Suite("URLQueryEncoder Parametrized Tests")
struct URLQueryEncoderParametrizedTests {

    // MARK: - Scalar properties

    @Test("Scalar encoding is deterministic across runs",
          arguments: [
            "alpha", "bravo", "with space", "한글", "1+1=2",
            "/path?token=abc", "", " ",
          ])
    func scalarEncodingIsDeterministic(value: String) throws {
        struct Wrap: Encodable { let key: String }
        let encoder = URLQueryEncoder()
        let first = try encoder.encode(Wrap(key: value))
        let second = try encoder.encode(Wrap(key: value))
        #expect(first == second, "Encoding the same scalar twice must produce identical query items")
        #expect(first == [URLQueryItem(name: "key", value: value)])
    }

    @Test("Integer scalar encoding renders as decimal",
          arguments: [-1_000_000, -1, 0, 1, 42, 1_000_000])
    func integerScalarEncoding(value: Int) throws {
        struct Wrap: Encodable { let count: Int }
        let items = try URLQueryEncoder().encode(Wrap(count: value))
        #expect(items == [URLQueryItem(name: "count", value: String(value))])
    }

    @Test("Boolean scalar encoding uses lowercase truthy/falsey words",
          arguments: [true, false])
    func booleanScalarEncoding(flag: Bool) throws {
        struct Wrap: Encodable { let active: Bool }
        let items = try URLQueryEncoder().encode(Wrap(active: flag))
        let value = items.first?.value
        // JSONEncoder-style boolean rendering — true/false lowercase.
        #expect(value == String(flag))
    }

    // MARK: - Top-level requirements

    @Test("Top-level scalar without rootKey throws unsupportedTopLevelValue",
          arguments: ["alpha", "1", ""])
    func scalarTopLevelWithoutRootThrows(_ value: String) {
        struct Wrap: Encodable {
            let value: String
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(value)
            }
        }
        let encoder = URLQueryEncoder()
        #expect(throws: URLQueryEncoder.EncodingError.self) {
            _ = try encoder.encode(Wrap(value: value))
        }
    }

    @Test("Top-level scalar with rootKey emits a single item",
          arguments: ["a", "b", "c"])
    func scalarTopLevelWithRoot(_ value: String) throws {
        struct Wrap: Encodable {
            let value: String
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(value)
            }
        }
        let items = try URLQueryEncoder().encode(Wrap(value: value), rootKey: "token")
        #expect(items == [URLQueryItem(name: "token", value: value)])
    }

    // MARK: - Nested object — bracket notation invariant

    @Test("Single-level nested object emits user[name]= flat keys")
    func singleLevelNestedObject() throws {
        struct User: Encodable { let name: String }
        struct Wrap: Encodable { let user: User }

        let items = try URLQueryEncoder().encode(Wrap(user: User(name: "alice")))
        #expect(items.map { "\($0.name)=\($0.value ?? "")" } == ["user[name]=alice"])
    }

    @Test("Two-level nested object emits filter[user][name]= chain")
    func twoLevelNestedObject() throws {
        struct User: Encodable { let name: String }
        struct Filter: Encodable { let user: User }
        struct Wrap: Encodable { let filter: Filter }

        let items = try URLQueryEncoder().encode(
            Wrap(filter: Filter(user: User(name: "alice")))
        )
        #expect(items.map { "\($0.name)=\($0.value ?? "")" } == ["filter[user][name]=alice"])
    }

    // MARK: - Arrays — indexed bracket invariant

    @Test("Array of scalars emits indexed brackets",
          arguments: [
            (["a"], "tags[0]=a"),
            (["a", "b"], "tags[0]=a&tags[1]=b"),
            (["x", "y", "z"], "tags[0]=x&tags[1]=y&tags[2]=z"),
          ])
    func arrayOfScalars(_ payload: ([String], String)) throws {
        struct Wrap: Encodable { let tags: [String] }
        let items = try URLQueryEncoder().encode(Wrap(tags: payload.0))
        let serialized = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        #expect(serialized == payload.1)
    }

    @Test("Empty array emits no items")
    func emptyArrayEmitsNothing() throws {
        struct Wrap: Encodable { let tags: [String] }
        let items = try URLQueryEncoder().encode(Wrap(tags: []))
        #expect(items.isEmpty)
    }

    @Test("Empty object emits no items for that key")
    func emptyObjectEmitsNothing() throws {
        struct User: Encodable {}
        struct Wrap: Encodable { let user: User }
        let items = try URLQueryEncoder().encode(Wrap(user: User()))
        #expect(items.isEmpty)
    }

    // MARK: - Determinism (sorted keys)

    @Test("Top-level keys are sorted alphabetically regardless of declaration order")
    func topLevelKeysAreSorted() throws {
        struct Wrap: Encodable {
            let zebra: String
            let alpha: String
            let middle: String
        }
        let items = try URLQueryEncoder().encode(
            Wrap(zebra: "Z", alpha: "A", middle: "M")
        )
        let names = items.map(\.name)
        #expect(names == ["alpha", "middle", "zebra"])
    }

    @Test("Nested object keys are sorted alphabetically")
    func nestedObjectKeysAreSorted() throws {
        struct User: Encodable { let zebra: String; let alpha: String }
        struct Wrap: Encodable { let user: User }

        let items = try URLQueryEncoder().encode(
            Wrap(user: User(zebra: "Z", alpha: "A"))
        )
        let names = items.map(\.name)
        #expect(names == ["user[alpha]", "user[zebra]"])
    }

    // MARK: - Roundtrip via encodeForm

    @Test("encodeForm matches encode percent-encoded form for simple objects",
          arguments: [
            ("alice", 30),
            ("bob with space", 99),
            ("한글이름", 10),
          ])
    func encodeFormMatchesEncode(_ payload: (String, Int)) throws {
        struct Wrap: Encodable { let name: String; let age: Int }
        let value = Wrap(name: payload.0, age: payload.1)

        let items = try URLQueryEncoder().encode(value)
        let formData = try URLQueryEncoder().encodeForm(value)

        var components = URLComponents()
        components.queryItems = items
        let expected = (components.percentEncodedQuery ?? "")

        #expect(String(data: formData, encoding: .utf8) == expected)
    }

    // MARK: - Optional / nil handling

    @Test("Nil optionals emit no key (skipped, not empty)")
    func optionalNilEmitsNoKey() throws {
        struct Wrap: Encodable {
            let user: String?
            let count: Int?
        }
        let items = try URLQueryEncoder().encode(Wrap(user: nil, count: nil))
        #expect(items.isEmpty)
    }

    @Test("Mixed nil + non-nil only emits non-nil keys",
          arguments: [
            ("alice", "alice"),
            ("", ""),
          ])
    func optionalMixedSkipsNil(_ payload: (String, String)) throws {
        struct Wrap: Encodable {
            let user: String?
            let count: Int?
        }
        let items = try URLQueryEncoder().encode(Wrap(user: payload.0, count: nil))
        #expect(items == [URLQueryItem(name: "user", value: payload.1)])
    }

    // MARK: - Edge characters

    @Test("Reserved URL characters survive flattening",
          arguments: [
            "a&b", "a=b", "a?b", "a#b", "a/b",
            "a%20b", "100%", "/path?token=abc",
          ])
    func reservedCharsArePreservedInValue(_ value: String) throws {
        struct Wrap: Encodable { let payload: String }
        let items = try URLQueryEncoder().encode(Wrap(payload: value))
        // The encoder produces logical URLQueryItem values; URL percent-
        // encoding happens later when these are attached to URLComponents.
        // The logical value must match the input verbatim.
        #expect(items == [URLQueryItem(name: "payload", value: value)])
    }
}
