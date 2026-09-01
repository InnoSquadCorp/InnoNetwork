import Foundation

struct HLSMediaEncryptionState: Sendable {
    struct AES128IdentityKey: Sendable {
        let keyURL: URL
        let explicitInitializationVector: Data?
    }

    private var declarations: [HLSMediaKeyDeclaration] = []

    /// The resource-facing declaration, preferring a usable identity AES key.
    var selectedDeclaration: HLSMediaKeyDeclaration? {
        declarations.first(where: \.isAES128Identity)
            ?? declarations.first
    }

    var aes128IdentityKey: AES128IdentityKey? {
        declarations.first(where: \.isAES128Identity).map {
            AES128IdentityKey(
                keyURL: $0.keyURL,
                explicitInitializationVector:
                    $0.explicitInitializationVector
            )
        }
    }

    var unsupportedMethod: String? {
        guard aes128IdentityKey == nil else {
            return nil
        }
        return declarations.first?.method
    }

    mutating func apply(_ directive: HLSMediaKeyDirective) {
        switch directive {
        case .clear:
            declarations.removeAll(keepingCapacity: true)
        case .select(let declaration):
            if let index = declarations.firstIndex(where: {
                $0.normalizedKeyFormat
                    == declaration.normalizedKeyFormat
            }) {
                declarations[index] = declaration
            } else {
                declarations.append(declaration)
            }
        }
    }
}
