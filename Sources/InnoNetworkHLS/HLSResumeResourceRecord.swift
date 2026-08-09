import Foundation

/// URL-free identity for one resource in a resumable HLS transfer plan.
struct HLSResumeResourceRecord: Codable, Equatable, Sendable {
    let urlSHA256: String
    let byteRangeOffset: Int64?
    let byteRangeLength: Int64?
    let keyURLSHA256: String?
    let keySHA256: String?
    let initializationVectorSHA256: String?

    init(
        _ resource: HLSResourceTransfer,
        aes128KeySet: HLSAES128KeySet
    ) {
        self.urlSHA256 = HLSContentFingerprint.sha256(
            resource.url.absoluteString
        )
        self.byteRangeOffset = resource.byteRange?.offset
        self.byteRangeLength = resource.byteRange?.length
        self.keyURLSHA256 = resource.encryption.map {
            HLSContentFingerprint.sha256($0.keyURL.absoluteString)
        }
        self.keySHA256 = resource.encryption.flatMap {
            aes128KeySet.fingerprint(for: $0.keyURL)
        }
        self.initializationVectorSHA256 = resource.encryption.map {
            HLSContentFingerprint.sha256($0.initializationVector)
        }
    }
}
