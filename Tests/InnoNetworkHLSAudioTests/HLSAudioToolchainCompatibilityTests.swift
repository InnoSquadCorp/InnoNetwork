#if compiler(<6.4)
import Testing

@testable import InnoNetworkHLSAudio

@Suite("HLS audio toolchain compatibility")
struct HLSAudioToolchainCompatibilityTests {
    @Test("The compatibility target remains buildable before Xcode 27")
    func compatibilityTargetBuilds() {}
}
#endif
