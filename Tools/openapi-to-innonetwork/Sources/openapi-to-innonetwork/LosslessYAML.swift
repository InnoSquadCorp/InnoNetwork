import Foundation
import InnoNetwork
import Yams

/// JSON-compatible YAML scalars are emitted from their lexemes, never NSNumber
/// or Double. Aliases, merge keys, custom tags and non-JSON number spellings fail.
func losslessYAMLJSON(_ text: String) throws -> Data {
    let limits = JSONProcessingLimits()
    guard text.utf8.count <= limits.maximumBytes, let root = try Yams.compose(yaml: text) else {
        throw GenerationError.parseFailure("YAML input exceeds limits or is empty")
    }
    var output = Data()
    var work = 0
    func append(_ data: Data) throws {
        guard data.count <= limits.maximumBytes - output.count else { throw JSONProcessingError.resourceLimit }
        output.append(data)
    }
    func emit(_ node: Node, depth: Int) throws {
        work += 1
        guard depth <= limits.maximumDepth, work <= limits.maximumNodes else { throw JSONProcessingError.resourceLimit }
        switch node {
        case .scalar(let value):
            switch node.tag {
            case Tag(.int), Tag(.float):
                let bytes = Data(value.string.utf8)
                _ = try PreservedJSON(data: bytes)
                guard bytes.first.map({ $0 == 45 || (48...57).contains($0) }) == true else {
                    throw GenerationError.parseFailure("Only JSON-compatible YAML numeric spellings are supported")
                }
                try append(bytes)
            case Tag(.bool):
                guard let boolean = node.bool else { throw GenerationError.parseFailure("Invalid YAML boolean") }
                try append(Data((boolean ? "true" : "false").utf8))
            case Tag(.null): try append(Data("null".utf8))
            case Tag(.str), Tag(.timestamp): try append(JSONEncoder().encode(value.string))
            default: throw GenerationError.parseFailure("Unsupported YAML scalar tag")
            }
        case .sequence(let sequence):
            guard node.tag == Tag(.seq) else { throw GenerationError.parseFailure("Unsupported YAML sequence tag") }
            try append(Data("[".utf8))
            for (index, child) in sequence.enumerated() {
                if index > 0 { try append(Data(",".utf8)) }
                try emit(child, depth: depth + 1)
            }
            try append(Data("]".utf8))
        case .mapping(let mapping):
            guard node.tag == Tag(.map) else { throw GenerationError.parseFailure("Unsupported YAML mapping tag") }
            try append(Data("{".utf8))
            var names: Set<String> = []
            for (index, pair) in mapping.enumerated() {
                guard case .scalar(let key) = pair.key, key.string != "<<", names.insert(key.string).inserted else {
                    throw GenerationError.parseFailure("YAML keys must be unique scalars without merges")
                }
                guard
                    [Tag(.str), Tag(.int), Tag(.float), Tag(.bool), Tag(.null), Tag(.timestamp)].contains(pair.key.tag)
                else { throw GenerationError.parseFailure("Unsupported YAML key tag") }
                if index > 0 { try append(Data(",".utf8)) }
                try append(JSONEncoder().encode(key.string))
                try append(Data(":".utf8))
                try emit(pair.value, depth: depth + 1)
            }
            try append(Data("}".utf8))
        case .alias: throw GenerationError.parseFailure("YAML aliases are not supported")
        }
    }
    try emit(root, depth: 1)
    return output
}
