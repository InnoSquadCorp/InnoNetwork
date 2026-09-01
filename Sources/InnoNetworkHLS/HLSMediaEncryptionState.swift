import Foundation

struct HLSMediaEncryptionState: Sendable {
    struct AES128IdentityKey: Sendable {
        let keyURL: URL
        let explicitInitializationVector: Data?
    }

    private struct UnsupportedAlternative: Sendable {
        let keyFormat: String
        let method: String
    }

    private(set) var aes128IdentityKey: AES128IdentityKey?
    private var unsupportedAlternatives: [UnsupportedAlternative] = []

    var unsupportedMethod: String? {
        guard aes128IdentityKey == nil else {
            return nil
        }
        return unsupportedAlternatives.first?.method
    }

    mutating func clear() {
        aes128IdentityKey = nil
        unsupportedAlternatives.removeAll(keepingCapacity: true)
    }

    mutating func selectAES128Identity(
        keyURL: URL,
        explicitInitializationVector: Data?
    ) {
        aes128IdentityKey = AES128IdentityKey(
            keyURL: keyURL,
            explicitInitializationVector:
                explicitInitializationVector
        )
        unsupportedAlternatives.removeAll {
            $0.keyFormat == "identity"
        }
    }

    mutating func selectUnsupported(
        method: String,
        keyFormat: String
    ) {
        let keyFormat = Self.normalizedKeyFormat(keyFormat)
        if keyFormat == "identity" {
            aes128IdentityKey = nil
        }
        let alternative = UnsupportedAlternative(
            keyFormat: keyFormat,
            method: method
        )
        if let index = unsupportedAlternatives.firstIndex(where: {
            $0.keyFormat == keyFormat
        }) {
            unsupportedAlternatives[index] = alternative
        } else {
            unsupportedAlternatives.append(alternative)
        }
    }

    private static func normalizedKeyFormat(
        _ keyFormat: String
    ) -> String {
        keyFormat.caseInsensitiveCompare("identity") == .orderedSame
            ? "identity"
            : keyFormat
    }
}
