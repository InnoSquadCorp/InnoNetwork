import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download Manager Init Tests")
struct DownloadManagerInitTests {

    @Test("Throwing init surfaces duplicateSessionIdentifier")
    func throwingInitRejectsDuplicate() throws {
        let identifier = "test.init.duplicate.\(UUID().uuidString)"
        let configuration = DownloadConfiguration.safeDefaults(sessionIdentifier: identifier)

        let first = try DownloadManager(configuration: configuration)
        defer { _ = first }

        #expect(throws: DownloadManagerError.duplicateSessionIdentifier(identifier)) {
            _ = try DownloadManager(configuration: configuration)
        }
    }
}
