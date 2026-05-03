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

    @Test(
        "Scalar encoding is deterministic across runs",
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

    @Test(
        "Integer scalar encoding renders as decimal",
        arguments: [-1_000_000, -1, 0, 1, 42, 1_000_000])
    func integerScalarEncoding(value: Int) throws {
        struct Wrap: Encodable { let count: Int }
        let items = try URLQueryEncoder().encode(Wrap(count: value))
        #expect(items == [URLQueryItem(name: "count", value: String(value))])
    }

    @Test(
        "Boolean scalar encoding uses lowercase truthy/falsey words",
        arguments: [true, false])
    func booleanScalarEncoding(flag: Bool) throws {
        struct Wrap: Encodable { let active: Bool }
        let items = try URLQueryEncoder().encode(Wrap(active: flag))
        let value = items.first?.value
        // JSONEncoder-style boolean rendering — true/false lowercase.
        #expect(value == String(flag))
    }

    // MARK: - Top-level requirements

    @Test(
        "Top-level scalar without rootKey throws unsupportedTopLevelValue",
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

    @Test(
        "Top-level scalar with rootKey emits a single item",
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

    @Test(
        "Array of scalars emits indexed brackets",
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

    @Test(
        "Array strategy controls scalar array keys",
        arguments: [
            (URLQueryArrayEncodingStrategy.indexed, "tags[0]=a&tags[1]=b"),
            (.bracketed, "tags[]=a&tags[]=b"),
            (.repeated, "tags=a&tags=b"),
        ])
    func arrayStrategyControlsScalarKeys(_ payload: (URLQueryArrayEncodingStrategy, String)) throws {
        struct Wrap: Encodable { let tags: [String] }
        let encoder = URLQueryEncoder(arrayEncodingStrategy: payload.0)

        let items = try encoder.encode(Wrap(tags: ["a", "b"]))
        let serialized = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")

        #expect(serialized == payload.1)
    }

    @Test("Bracketed strategy applies to nested arrays")
    func bracketedStrategyAppliesToNestedArrays() throws {
        struct Filter: Encodable { let tags: [String] }
        struct Wrap: Encodable { let filter: Filter }

        let items = try URLQueryEncoder(arrayEncodingStrategy: .bracketed)
            .encode(Wrap(filter: Filter(tags: ["swift", "ios"])))

        #expect(
            items.map { "\($0.name)=\($0.value ?? "")" } == [
                "filter[tags][]=swift",
                "filter[tags][]=ios",
            ])
    }

    @Test("Repeated strategy applies to top-level arrays with rootKey")
    func repeatedStrategyAppliesToTopLevelArraysWithRootKey() throws {
        let items = try URLQueryEncoder(arrayEncodingStrategy: .repeated)
            .encode(["swift", "ios"], rootKey: "tag")

        #expect(
            items.map { "\($0.name)=\($0.value ?? "")" } == [
                "tag=swift",
                "tag=ios",
            ])
    }

    @Test("Array strategy is shared by form-urlencoded encoding")
    func arrayStrategyIsSharedByFormEncoding() throws {
        struct Wrap: Encodable { let tags: [String] }

        let data = try URLQueryEncoder(arrayEncodingStrategy: .bracketed)
            .encodeForm(Wrap(tags: ["a", "b"]))

        // `[` and `]` are not in the form-urlencoded unreserved set, so they
        // must be percent-encoded. They appear in the *name* portion of the
        // pair; the values are plain ASCII.
        #expect(String(data: data, encoding: .utf8) == "tags%5B%5D=a&tags%5B%5D=b")
    }

    @Test("Large scalar arrays preserve order")
    func largeScalarArraysPreserveOrder() throws {
        struct Wrap: Encodable { let tags: [String] }
        let values = (0..<2_048).map { "tag-\($0)" }

        let items = try URLQueryEncoder().encode(Wrap(tags: values))

        #expect(items.count == values.count)
        #expect(items.first == URLQueryItem(name: "tags[0]", value: "tag-0"))
        #expect(items.last == URLQueryItem(name: "tags[2047]", value: "tag-2047"))
    }

    @Test("ISO8601 date encoding remains deterministic")
    func iso8601DateEncodingIsDeterministic() throws {
        struct Wrap: Encodable { let date: Date }
        let encoder = URLQueryEncoder(dateEncodingStrategy: .iso8601)
        let value = Wrap(date: Date(timeIntervalSince1970: 0))

        let first = try encoder.encode(value)
        let second = try encoder.encode(value)

        #expect(first == [URLQueryItem(name: "date", value: "1970-01-01T00:00:00Z")])
        #expect(second == first)
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
        struct User: Encodable {
            let zebra: String
            let alpha: String
        }
        struct Wrap: Encodable { let user: User }

        let items = try URLQueryEncoder().encode(
            Wrap(user: User(zebra: "Z", alpha: "A"))
        )
        let names = items.map(\.name)
        #expect(names == ["user[alpha]", "user[zebra]"])
    }

    // MARK: - Roundtrip via encodeForm

    @Test(
        "encodeForm produces application/x-www-form-urlencoded body for simple objects",
        arguments: [
            ("alice", 30, "age=30&name=alice"),
            ("bob with space", 99, "age=99&name=bob+with+space"),
            (
                "한글이름", 10,
                "age=10&name=%ED%95%9C%EA%B8%80%EC%9D%B4%EB%A6%84"
            ),
        ])
    func encodeFormMatchesFormUrlencodedSpec(_ payload: (String, Int, String)) throws {
        struct Wrap: Encodable {
            let name: String
            let age: Int
        }
        let value = Wrap(name: payload.0, age: payload.1)

        let formData = try URLQueryEncoder().encodeForm(value)
        #expect(String(data: formData, encoding: .utf8) == payload.2)
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

    @Test(
        "Mixed nil + non-nil only emits non-nil keys",
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

    @Test(
        "Reserved URL characters survive flattening",
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

    // MARK: - Non-conforming Float / Double

    @Test("NaN throws by default")
    func nanThrowsByDefault() {
        struct Wrap: Encodable { let x: Double }
        let encoder = URLQueryEncoder()
        #expect(throws: URLQueryEncoder.EncodingError.self) {
            _ = try encoder.encode(Wrap(x: .nan))
        }
    }

    @Test("Infinity throws by default for Float and Double")
    func infinityThrowsByDefault() {
        struct WrapD: Encodable { let x: Double }
        struct WrapF: Encodable { let x: Float }
        let encoder = URLQueryEncoder()
        #expect(throws: URLQueryEncoder.EncodingError.self) {
            _ = try encoder.encode(WrapD(x: .infinity))
        }
        #expect(throws: URLQueryEncoder.EncodingError.self) {
            _ = try encoder.encode(WrapF(x: -.infinity))
        }
    }

    @Test("convertToString strategy emits the configured sentinels")
    func convertToStringStrategyEmitsSentinels() throws {
        struct Wrap: Encodable { let x: Double }
        let encoder = URLQueryEncoder(
            nonConformingFloatEncodingStrategy: .convertToString(
                positiveInfinity: "+inf",
                negativeInfinity: "-inf",
                nan: "nan"
            )
        )
        let items = try encoder.encode(Wrap(x: .nan))
        #expect(items == [URLQueryItem(name: "x", value: "nan")])
        let infItems = try encoder.encode(Wrap(x: .infinity))
        #expect(infItems == [URLQueryItem(name: "x", value: "+inf")])
    }

    // MARK: - Decimal locale-independence

    @Test("Decimal stringification is locale-independent")
    func decimalIsLocaleIndependent() throws {
        struct Wrap: Encodable { let amount: Decimal }
        // `Decimal.description` always uses POSIX numeric form regardless
        // of the user's regional settings, so a value like 1.5 must never
        // round-trip as "1,5".
        let items = try URLQueryEncoder().encode(Wrap(amount: Decimal(string: "1.5")!))
        #expect(items == [URLQueryItem(name: "amount", value: "1.5")])
    }
}
