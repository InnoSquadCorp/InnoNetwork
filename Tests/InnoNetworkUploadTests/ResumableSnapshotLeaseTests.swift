import Foundation
import Testing

@testable import InnoNetworkUpload

@Suite("Resumable snapshot leases")
struct ResumableSnapshotLeaseTests {
    @Test("cleanup preserves live leases, foreign files and symlinks")
    func cleanupIsSelective() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try ResumableSnapshotLease(parent: parent)
        let root = first.url.deletingLastPathComponent()
        let orphan = root.appendingPathComponent("\(UUID().uuidString).snapshot")
        #expect(
            FileManager.default.createFile(
                atPath: orphan.path, contents: Data([1]), attributes: [.posixPermissions: 0o600]))
        let foreign = root.appendingPathComponent("foreign.snapshot")
        try Data([2]).write(to: foreign)
        let symlink = root.appendingPathComponent("\(UUID().uuidString).snapshot")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: foreign)
        let second = try ResumableSnapshotLease(parent: parent)
        withExtendedLifetime((first, second)) {
            #expect(FileManager.default.fileExists(atPath: first.url.path))
            #expect(FileManager.default.fileExists(atPath: second.url.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(FileManager.default.fileExists(atPath: foreign.path))
            #expect(FileManager.default.fileExists(atPath: symlink.path))
        }
    }

    @Test("managed directory symlinks are refused")
    func symlinkRootRejected() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let foreign = parent.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("innonetwork-resumable-v1"), withDestinationURL: foreign)
        #expect(throws: ResumableUploadError.unreadableFile) { try ResumableSnapshotLease(parent: parent) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }
}
