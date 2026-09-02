import Foundation

enum HLSKeyAttributeParser {
    static func parseKeyFormatVersions(
        _ value: String?
    ) throws -> [Int] {
        guard let value else {
            return [1]
        }
        let fields = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        var versions: [Int] = []
        versions.reserveCapacity(fields.count)
        for field in fields {
            guard
                let version = Int(field),
                version > 0,
                String(version) == field
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            versions.append(version)
        }
        guard !versions.isEmpty else {
            throw HLSDownloadError.invalidPlaylist
        }
        return versions
    }

    static func parseInitializationVector(
        _ value: String
    ) throws -> Data {
        guard value.lowercased().hasPrefix("0x") else {
            throw HLSDownloadError.invalidPlaylist
        }
        let hexadecimal = String(value.dropFirst(2))
        guard
            !hexadecimal.isEmpty,
            hexadecimal.count <= 32,
            hexadecimal.allSatisfy(\.isHexDigit)
        else {
            throw HLSDownloadError.invalidPlaylist
        }
        let padded =
            String(repeating: "0", count: 32 - hexadecimal.count)
            + hexadecimal
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = padded.startIndex
        while index < padded.endIndex {
            let endIndex = padded.index(index, offsetBy: 2)
            guard
                let byte = UInt8(padded[index..<endIndex], radix: 16)
            else {
                throw HLSDownloadError.invalidPlaylist
            }
            bytes.append(byte)
            index = endIndex
        }
        return Data(bytes)
    }
}
