import SwiftDiagnostics
import SwiftSyntax

extension APIDefinitionMacro {
    static func validatePathLiteral(
        _ path: String,
        anchor: some SyntaxProtocol
    ) throws {
        guard !path.contains("?"), !path.contains("#") else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition path must not contain query or fragment components; declare query values through the query property.",
                id: "api-definition-path-component"
            ).error(at: anchor)
        }

        var index = path.startIndex
        while index < path.endIndex {
            guard path[index] == "%" else {
                index = path.index(after: index)
                continue
            }
            let first = path.index(after: index)
            guard first < path.endIndex else {
                throw invalidPercentEscape(at: anchor)
            }
            let second = path.index(after: first)
            guard second < path.endIndex,
                isASCIIHexDigit(path[first]),
                isASCIIHexDigit(path[second])
            else {
                throw invalidPercentEscape(at: anchor)
            }
            index = path.index(after: second)
        }

        guard !containsDotSegment(path) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition path must not contain '.' or '..' segments, including percent-encoded spellings.",
                id: "api-definition-dot-segment"
            ).error(at: anchor)
        }
    }

    static func containsDotSegment(_ path: String) -> Bool {
        var candidate = path
        for _ in 0...path.utf8.count {
            if candidate.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == "." || $0 == ".."
            }) {
                return true
            }
            guard let decoded = decodePercentEscapes(candidate), decoded != candidate else { break }
            candidate = decoded
        }
        return false
    }

    static func decodePercentEscapes(_ value: String) -> String? {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            guard input[index] == 0x25 else {
                output.append(input[index])
                index += 1
                continue
            }
            guard index + 2 < input.count,
                let high = hexValue(input[index + 1]),
                let low = hexValue(input[index + 2])
            else {
                return nil
            }
            output.append((high << 4) | low)
            index += 3
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    static func isASCIIHexDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
            let value = character.unicodeScalars.first?.value
        else {
            return false
        }
        switch value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }

    static func invalidPercentEscape(
        at anchor: some SyntaxProtocol
    ) -> DiagnosticsError {
        InnoNetworkMacroDiagnostic(
            "@APIDefinition path contains an invalid percent escape.",
            id: "api-definition-invalid-percent-escape"
        ).error(at: anchor)
    }

    static func pathWitness(
        _ path: String,
        hasPlaceholders: Bool,
        accessPrefix: String
    ) -> String {
        guard hasPlaceholders else {
            return "\(accessPrefix)var path: Swift.String { \"\(path)\" }"
        }
        return """
            \(accessPrefix)var path: Swift.String {
                func _innoNetworkRequirePathValue<Value>(_ value: Value) -> Value {
                    value
                }
                @available(*, unavailable, message: "@APIDefinition path placeholder values cannot be Optional; unwrap the value and define its nil behavior before constructing the endpoint.")
                func _innoNetworkRequirePathValue<Value>(_ value: Value?) -> Value {
                    fatalError()
                }
                return "\(path)"
            }
            """
    }

    static func interpolatedPath(
        _ path: String,
        properties: [String: StoredProperty],
        usedProperties: inout Set<String>,
        anchor: some SyntaxProtocol
    ) throws -> String {
        var result = ""
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            if character == "{" {
                guard let close = path[index...].firstIndex(of: "}") else {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path contains an unterminated placeholder.",
                        id: "api-definition-unterminated-placeholder"
                    ).error(at: anchor)
                }
                let nameStart = path.index(after: index)
                let name = String(path[nameStart..<close])
                guard !name.isEmpty, let property = properties[name] else {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} must match a stored property.",
                        id: "api-definition-unknown-placeholder"
                    ).error(at: anchor)
                }
                if property.isOptional {
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} cannot reference an Optional stored property.",
                        id: "api-definition-optional-placeholder"
                    ).error(at: anchor)
                }
                switch property.typeKind {
                case .opaque:
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} cannot reference an opaque (`some`) type. Declare the property with a concrete `LosslessStringConvertible & Sendable` type.",
                        id: "api-definition-opaque-placeholder"
                    ).error(at: anchor)
                case .genericParameter:
                    throw InnoNetworkMacroDiagnostic(
                        "@APIDefinition path placeholder {\(name)} cannot reference a generic parameter. Declare the property with a concrete `LosslessStringConvertible & Sendable` type.",
                        id: "api-definition-generic-placeholder"
                    ).error(at: anchor)
                case .concrete:
                    break
                }
                usedProperties.insert(name)
                result +=
                    "\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(_innoNetworkRequirePathValue(\(name))))"
                index = path.index(after: close)
            } else if character == "}" {
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition path contains an unmatched closing brace.",
                    id: "api-definition-unmatched-placeholder"
                ).error(at: anchor)
            } else {
                result.append(character)
                index = path.index(after: index)
            }
        }
        return result
    }
}
