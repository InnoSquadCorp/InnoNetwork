import SwiftDiagnostics
import SwiftSyntax

extension EndpointDefinitionExpansion {
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

        let scalars = path.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index] == "%" else {
                index = scalars.index(after: index)
                continue
            }
            let first = scalars.index(after: index)
            guard first < scalars.endIndex else {
                throw invalidPercentEscape(at: anchor)
            }
            let second = scalars.index(after: first)
            guard second < scalars.endIndex,
                isASCIIHexDigit(scalars[first]),
                isASCIIHexDigit(scalars[second])
            else {
                throw invalidPercentEscape(at: anchor)
            }
            index = scalars.index(after: second)
        }

        guard !containsDotSegment(path) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition path must not contain '.' or '..' segments, including percent-encoded spellings.",
                id: "api-definition-dot-segment"
            ).error(at: anchor)
        }
    }

    static func containsDotSegment(_ path: String) -> Bool {
        // Match runtime's byte-delimited fixed point, including escapes whose
        // hex digits are themselves encoded. Each reduction removes two bytes,
        // rather than performing one whole-path scan per nesting layer.
        var output: [UInt8] = []
        output.reserveCapacity(path.utf8.count)
        for byte in path.utf8 {
            output.append(byte)
            while output.count >= 3 {
                let start = output.count - 3
                guard output[start] == 0x25,
                    let high = hexValue(output[start + 1]),
                    let low = hexValue(output[start + 2])
                else { break }
                output.removeLast(3)
                output.append((high << 4) | low)
            }
        }
        return output.split(whereSeparator: { $0 == 0x2F || $0 == 0x5C }).contains {
            ($0.count == 1 || $0.count == 2) && $0.allSatisfy { $0 == 0x2E }
        }
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
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
                    "\\(InnoNetwork.EndpointPathEncoding.percentEncodedSegment(_innoNetworkRequirePathValue(self.\(property.sourceName))))"
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
