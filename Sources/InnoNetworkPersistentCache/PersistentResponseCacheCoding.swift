import Foundation

extension JSONEncoder {
    /// Encoder used to serialize the persistent cache index. Stable across
    /// process launches: ISO-8601 dates and sorted keys keep the on-disk
    /// representation deterministic.
    static var persistentCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    /// Decoder paired with ``JSONEncoder/persistentCache``.
    static var persistentCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension PersistentResponseCacheConfiguration.DataProtectionClass {
    /// Foundation `FileProtectionType` corresponding to this protection class.
    ///
    /// Used by the cache when applying file attributes; platforms that do not
    /// support file protection treat the call as a no-op.
    var fileProtectionType: FileProtectionType {
        switch self {
        case .complete:
            return .complete
        case .completeUnlessOpen:
            return .completeUnlessOpen
        case .completeUntilFirstUserAuthentication:
            return .completeUntilFirstUserAuthentication
        case .none:
            return .none
        }
    }
}
