import Foundation
import InnoNetwork

@main struct CompiledSchemaFixture {
    static func main() throws {
        let raw = Data(#"{"id":9007199254740993,"name":"😀","unknown":1e999999999999}"#.utf8)
        let value = try PreservedJSONCoding.decode(ConstrainedChoice.self, from: raw)
        precondition(value.matchingBranches == [0, 1])
        let branch = try value.asBranch0()
        let encoded = try PreservedJSONCoding.encode(value)
        precondition(branch?.json.data == raw)
        precondition(encoded == raw)
        let one = try ConstrainedChoice(json: PreservedJSON(data: Data(#"{"id":9007199254740994,"name":"x"}"#.utf8)))
        precondition(one.matchingBranches == [0])
        do {
            _ = try ConstrainedChoice(json: PreservedJSON(data: Data(#"{"id":9007199254740992,"name":"x"}"#.utf8)))
            preconditionFailure("Invalid numeric branch accepted")
        } catch JSONProcessingError.noMatchingSchema {}
        print("Compiled schema constraints: exact bytes and zero/one/multiple branches passed")
    }
}
