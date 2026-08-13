import AVFoundation

/// Isolates SDK-new playback-mode metrics from the package's Xcode 26 floor.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
enum HLSPlaybackModeMetricMapper {
    static func map(
        _ metric: AVMetricEvent,
        context: HLSPlaybackMetricContext
    ) -> HLSPlaybackMetricEvent? {
        #if compiler(>=6.4)
        if #available(macOS 27,
        iOS 27,
        tvOS 27,
        watchOS 27,
        visionOS 27,
        *), let event = metric as? AVMetricPlaybackModeSwitchEvent {
            return .playbackModeChanged(
                context,
                mode: playbackMode(event.mode)
            )
        }
        #endif
        return nil
    }

    #if compiler(>=6.4)
    @available(
        macOS 27,
        iOS 27,
        tvOS 27,
        watchOS 27,
        visionOS 27,
        *
    )
    private static func playbackMode(
        _ mode: AVMetricPlaybackMode
    ) -> HLSPlaybackMode {
        switch mode {
        case .local:
            return .local
        case .airPlayVideo:
            return .airPlayVideo
        @unknown default:
            return .other
        }
    }
    #endif
}
