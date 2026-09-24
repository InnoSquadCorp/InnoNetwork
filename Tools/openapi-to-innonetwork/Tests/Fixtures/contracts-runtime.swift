import Foundation

@main
enum ContractRuntime {
    static func main() throws {
        let decoder = JSONDecoder()
        let cat = try decoder.decode(Pet.self, from: Data(#"{"kind":"cat","lives":9}"#.utf8))
        guard case .variant0(let value) = cat, value.lives == 9 else { fatalError("discriminator routing") }
        let encoded = try JSONEncoder().encode(cat)
        let roundtrip = try decoder.decode(Pet.self, from: encoded)
        precondition(roundtrip == cat)
        do {
            _ = try decoder.decode(Pet.self, from: Data(#"{"kind":"unknown","lives":9}"#.utf8))
            fatalError("unknown discriminator accepted")
        } catch is DecodingError {}
        do {
            _ = try JSONEncoder().encode(Pet.variant0(Cat(kind: "dog", lives: 9)))
            fatalError("mismatched discriminator encoded")
        } catch is EncodingError {}
        let nullable = try decoder.decode(NullableRecord.self, from: Data(#"{"note":null}"#.utf8))
        precondition(nullable.note == nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nullable)) as! [String: Any]
        precondition(object["note"] is NSNull)
        do {
            _ = try decoder.decode(NullableRecord.self, from: Data("{}".utf8))
            fatalError("missing required nullable property accepted")
        } catch is DecodingError {}
        print("generated composition and nullable roundtrip: PASS")
    }
}
