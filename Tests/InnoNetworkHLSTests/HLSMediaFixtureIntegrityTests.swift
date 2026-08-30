import CryptoKit
import Foundation
import Testing

@Suite("HLS media fixture integrity")
struct HLSMediaFixtureIntegrityTests {
    @Test("embedded video playlists satisfy independent-segment authoring")
    func independentSegmentDeclarations() {
        let playlists = [
            HLSMediaFixtures.transportStreamPlaylist,
            HLSMediaFixtures.fragmentedMP4Playlist,
        ]

        for playlist in playlists {
            #expect(
                playlist.split(separator: "\n").contains(
                    "#EXT-X-INDEPENDENT-SEGMENTS"
                )
            )
        }
    }

    @Test("embedded media fixtures retain exact provenance hashes")
    func provenanceHashes() throws {
        let fixtures: [(Data, String)] = [
            (
                try HLSMediaFixtures.fragmentedMP4Initialization(),
                "9d5dfad0b34d79e363976edeea823601ad7527d5c03ff6a793213e2a46aac44b"
            ),
            (
                try HLSMediaFixtures.fragmentedMP4Segment0(),
                "42d991769870848bed1818b8a7b437835178cdf8b9da4ce7381f05df3cc732dd"
            ),
            (
                try HLSMediaFixtures.fragmentedMP4Segment1(),
                "c773e6bb59a394fa3874624a3c2a540337dcb2d781fa52c33e90abf6cb902454"
            ),
            (
                try HLSMediaFixtures.transportStreamSegment0(),
                "02ccf0367ea29464ac039eadab725e463386f96e15ac0f5995f216ff33e4e0f6"
            ),
        ]

        for (data, expectedHash) in fixtures {
            #expect(sha256(data) == expectedHash)
        }
    }

    @Test("embedded fMP4 fixtures retain complete top-level boxes")
    func fragmentedMP4Structure() throws {
        #expect(
            try topLevelBoxTypes(
                in: HLSMediaFixtures.fragmentedMP4Initialization()
            ) == ["ftyp", "moov"]
        )
        #expect(
            try topLevelBoxTypes(
                in: HLSMediaFixtures.fragmentedMP4Segment0()
            ) == ["styp", "sidx", "moof", "mdat"]
        )
        #expect(
            try topLevelBoxTypes(
                in: HLSMediaFixtures.fragmentedMP4Segment1()
            ) == ["styp", "sidx", "moof", "mdat"]
        )
    }

    @Test("embedded transport stream retains 188-byte packet sync")
    func transportStreamPacketStructure() throws {
        let data = try HLSMediaFixtures.transportStreamSegment0()

        #expect(data.count == 5_828)
        #expect(data.count.isMultiple(of: 188))
        for offset in stride(from: 0, to: data.count, by: 188) {
            #expect(data[offset] == 0x47)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func topLevelBoxTypes(
        in data: Data
    ) throws -> [String] {
        var types: [String] = []
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 8 else {
                throw FixtureStructureError.truncatedBox
            }
            let size =
                Int(data[offset]) << 24
                | Int(data[offset + 1]) << 16
                | Int(data[offset + 2]) << 8
                | Int(data[offset + 3])
            guard size >= 8, size <= data.count - offset else {
                throw FixtureStructureError.invalidBoxSize
            }
            let typeData = data[(offset + 4)..<(offset + 8)]
            guard
                let type = String(
                    data: typeData,
                    encoding: .ascii
                )
            else {
                throw FixtureStructureError.invalidBoxType
            }
            types.append(type)
            offset += size
        }
        return types
    }
}

private enum FixtureStructureError: Error {
    case truncatedBox
    case invalidBoxSize
    case invalidBoxType
}
