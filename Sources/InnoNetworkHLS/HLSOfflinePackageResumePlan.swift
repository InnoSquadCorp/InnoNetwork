import Foundation

extension HLSOfflinePackageResumeStore {
    struct PlanManifest: Codable, Equatable {
        let schemaVersion: Int
        let sourceURLSHA256: String
        let selectedVariant: HLSOfflinePackageManifest.Variant?
        let selectedIFrameVariant: HLSOfflinePackageManifest.Variant?
        let tracks: [Track]

        var resourcePaths: [String] {
            tracks.flatMap(\.resourcePaths)
        }

        init(
            sourceURL: URL,
            plan: HLSOfflinePackagePlan,
            aes128KeySet: HLSAES128KeySet
        ) {
            self.schemaVersion = HLSOfflinePackageResumeStore.schemaVersion
            self.sourceURLSHA256 = HLSContentFingerprint.sha256(
                sourceURL.absoluteString
            )
            self.selectedVariant = plan.selectedVariant.map(
                HLSOfflinePackageManifest.Variant.init
            )
            self.selectedIFrameVariant = plan.selectedIFrameVariant.map(
                HLSOfflinePackageManifest.Variant.init
            )
            self.tracks = plan.tracks.map {
                Track($0, aes128KeySet: aes128KeySet)
            }
        }

        struct Track: Codable, Equatable {
            let descriptor: HLSOfflinePackageManifest.Track
            let playlistIdentity: HLSContentIdentity
            let resources: [HLSResumeResourceRecord]
            let resourcePaths: [String]

            init(
                _ track: HLSOfflinePackageTrackPlan,
                aes128KeySet: HLSAES128KeySet
            ) {
                self.descriptor = HLSOfflinePackageManifest.Track(
                    track.descriptor
                )
                self.playlistIdentity = track.document.identity
                self.resources = track.resources.map {
                    HLSResumeResourceRecord(
                        HLSResourceTransfer(
                            url: $0.url,
                            byteRange: $0.byteRange,
                            encryption: $0.encryption
                        ),
                        aes128KeySet: aes128KeySet
                    )
                }
                self.resourcePaths =
                    HLSOfflineMediaPlaylistWriter
                    .resourceFileNames(for: track.resources)
                    .map { track.relativeDirectoryPath + "/" + $0 }
            }
        }
    }
}
