import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Manager Init Tests")
struct DownloadManagerInitTests {

    @Test("make(configuration:) constructs a manager without throwing for a unique identifier")
    func makeSucceedsForUniqueIdentifier() throws {
        // A randomized identifier guarantees no collision with the shared
        // singleton or with other test cases running in the same suite.
        let identifier = "test.make.\(UUID().uuidString)"
        let configuration = DownloadConfiguration.safeDefaults(sessionIdentifier: identifier)

        let manager = try DownloadManager.make(configuration: configuration)
        #expect(manager !== DownloadManager.shared)
    }

    @Test("make(configuration:) throws duplicateSessionIdentifier on conflict")
    func makeThrowsOnDuplicate() throws {
        let identifier = "test.make.duplicate.\(UUID().uuidString)"
        let configuration = DownloadConfiguration.safeDefaults(sessionIdentifier: identifier)

        // First manager succeeds and registers the identifier in
        // DownloadManager.activeSessionIdentifiers; the closure-scoped binding
        // keeps it alive until the assertion below runs.
        let first = try DownloadManager.make(configuration: configuration)
        defer { _ = first }

        do {
            _ = try DownloadManager.make(configuration: configuration)
            Issue.record("Expected duplicateSessionIdentifier but factory returned successfully")
        } catch let error as DownloadManagerError {
            switch error {
            case .duplicateSessionIdentifier(let conflicting):
                #expect(conflicting == identifier)
            }
        }
    }

    @Test("Throwing init still surfaces duplicateSessionIdentifier (parity with make)")
    func throwingInitParity() throws {
        let identifier = "test.init.duplicate.\(UUID().uuidString)"
        let configuration = DownloadConfiguration.safeDefaults(sessionIdentifier: identifier)

        let first = try DownloadManager(configuration: configuration)
        defer { _ = first }

        #expect(throws: DownloadManagerError.duplicateSessionIdentifier(identifier)) {
            _ = try DownloadManager(configuration: configuration)
        }
    }
}
