import Foundation

package struct StagedCompletion: Sendable, Equatable {
    package struct Manifest: Codable, Sendable, Equatable {
        package let taskID: String
        package let originalRequestURL: URL
        package let currentRequestURL: URL
        package let expectedByteCount: Int64
        package let key: String

        package init(
            taskID: String,
            originalRequestURL: URL,
            currentRequestURL: URL,
            expectedByteCount: Int64,
            key: String
        ) {
            self.taskID = taskID
            self.originalRequestURL = originalRequestURL
            self.currentRequestURL = currentRequestURL
            self.expectedByteCount = expectedByteCount
            self.key = key
        }
    }

    package let manifest: Manifest
    package let payloadURL: URL
    package let manifestURL: URL

    package init(
        manifest: Manifest,
        payloadURL: URL,
        manifestURL: URL
    ) {
        self.manifest = manifest
        self.payloadURL = payloadURL
        self.manifestURL = manifestURL
    }
}

/// Internal completion payload carried across the synchronous URLSession
/// delegate boundary. Production completions are always journal-backed; the
/// legacy case exists only for package tests that inject a temporary file
/// directly into the manager.
package enum DownloadCompletionPayload: Sendable, Equatable {
    case journaled(StagedCompletion)
    case legacy(URL)

    package var locationURL: URL {
        switch self {
        case .journaled(let completion):
            completion.payloadURL
        case .legacy(let url):
            url
        }
    }

}

package enum DownloadCompletionStagingError: Error, Sendable, Equatable {
    case invalidTaskID
    case missingOriginalRequestURL
    case missingCurrentRequestURL
    case invalidStagingRoot
    case invalidSource
    case sourceIsSymbolicLink
    case sourceIsDirectory
    case sourceIsNotRegularFile
    case invalidKey
    case artifactEscapesStagingRoot
    case artifactsAlreadyExist(String)
    case manifestTaskIDCollision(String)
    case incompleteArtifacts(String)
    case invalidManifest(String)
    case payloadSizeMismatch(expected: Int64, actual: Int64)
    case unsupportedArtifact(String)
    case fileSystemFailure(String)
}
