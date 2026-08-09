#if canImport(AVFoundation) && !os(tvOS)
import Foundation
import InnoNetwork

enum HLSAssetDownloadAdmission {
    static func validateSourceURL(_ sourceURL: URL) throws {
        guard sourceURL.scheme?.lowercased() == "https" else {
            throw HLSAssetDownloadSessionError.insecureSourceURL
        }
        do {
            try NetworkURLAdmission.validate(
                sourceURL,
                policy: .http(allowsInsecure: false)
            )
        } catch {
            throw HLSAssetDownloadSessionError.invalidSourceURL
        }
    }
}
#endif
