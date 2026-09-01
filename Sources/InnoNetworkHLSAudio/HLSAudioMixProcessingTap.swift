#if !os(watchOS)
import AVFoundation
import CoreAudioTypes
import CoreMedia
import Foundation
import MediaToolbox

/// Failures raised while attaching an HLS audio-mix processing tap.
public enum HLSAudioMixProcessingError: Error, Equatable, Sendable {
    /// The player item already has an application-owned audio mix.
    case audioMixAlreadyConfigured

    /// MediaToolbox could not create the processing tap.
    case tapCreationFailed(status: OSStatus)
}

extension HLSAudioMixProcessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .audioMixAlreadyConfigured:
            "The HLS player item already has an audio mix."
        case .tapCreationFailed:
            "MediaToolbox could not create the HLS audio-mix processing tap."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .audioMixAlreadyConfigured:
            "Detach or explicitly replace the existing audio mix before attaching this tap."
        case .tapCreationFailed:
            "Use a supported version 27 platform and a valid linear PCM preferred format."
        }
    }
}

/// Chooses where processing runs relative to the player's other audio effects.
public enum HLSAudioMixProcessingPosition: Equatable, Sendable {
    /// Processes decoded audio before the player's remaining effects.
    case preEffects

    /// Processes the final mix after the player's remaining effects.
    case postEffects
}

/// Stream-boundary flags delivered with one real-time processing callback.
public struct HLSAudioMixStreamFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The buffer starts a new continuous sequence after a start or seek.
    public static let startOfStream = Self(
        rawValue: kMTAudioProcessingTapFlag_StartOfStream
    )

    /// The source has reached the end of its current sequence.
    public static let endOfStream = Self(
        rawValue: kMTAudioProcessingTapFlag_EndOfStream
    )
}

/// Audio format and capacity supplied before real-time processing starts.
public struct HLSAudioMixPreparationContext: Sendable {
    /// The largest frame count MediaToolbox may request in one callback.
    public let maximumFrameCount: Int

    /// The actual linear PCM layout supplied to the processing callback.
    ///
    /// This may differ from the preferred format's numeric representation,
    /// interleaving, or sample size.
    public let processingFormat: AudioStreamBasicDescription
}

/// Metadata accompanying one in-place real-time audio callback.
public struct HLSAudioMixProcessingContext: Sendable {
    /// The number of valid frames in the supplied buffers.
    public let frameCount: Int

    /// Stream boundaries reported by MediaToolbox.
    public let streamFlags: HLSAudioMixStreamFlags

    /// The primary asset time range represented by the source frames.
    public let timeRange: CMTimeRange

    /// The actual linear PCM layout of the supplied buffers.
    public let processingFormat: AudioStreamBasicDescription
}

/// Synchronous callbacks for one HLS audio-mix processing tap.
///
/// `prepare` and `unprepare` are paired and may run more than once. `process`
/// runs on a real-time audio thread: it must not allocate, block, perform I/O,
/// acquire contended locks, or escape the supplied buffer pointers. The
/// processor must preserve the supplied frame count and buffer layout.
public struct HLSAudioMixProcessingCallbacks: Sendable {
    let prepare: (@Sendable (HLSAudioMixPreparationContext) -> Void)?
    let unprepare: (@Sendable () -> Void)?
    let process:
        @Sendable (
            UnsafeMutableAudioBufferListPointer,
            HLSAudioMixProcessingContext
        ) -> Void

    /// Creates callback ownership for one processing tap.
    public init(
        prepare:
            (@Sendable (HLSAudioMixPreparationContext) -> Void)? = nil,
        unprepare: (@Sendable () -> Void)? = nil,
        process:
            @escaping @Sendable (
                UnsafeMutableAudioBufferListPointer,
                HLSAudioMixProcessingContext
            ) -> Void
    ) {
        self.prepare = prepare
        self.unprepare = unprepare
        self.process = process
    }
}

/// Applies an in-place processing tap to the complete audio mix of one HLS
/// player item.
///
/// The tap owns only the audio mix it installs. The application retains the
/// player and owns every real-time processing decision. Existing audio mixes
/// are rejected instead of being overwritten or incompletely merged. Apple
/// does not provide mixed audio from FairPlay-protected content to this tap.
@available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
@MainActor
public final class HLSAudioMixProcessingTap {
    private let playerItem: AVPlayerItem
    private let processingTap: MTAudioProcessingTap

    /// The audio mix installed on the player item.
    public let audioMix: AVAudioMix

    /// Whether this tap's audio mix remains attached to the player item.
    public private(set) var isAttached = true

    /// Creates and attaches a preferred-format processing tap.
    ///
    /// The player item must represent HLS media and must not already have an
    /// audio mix. MediaToolbox may adjust the requested PCM memory layout; use
    /// the preparation context as the authoritative processing format. This
    /// tap is unavailable for FairPlay-protected audio.
    public init(
        playerItem: AVPlayerItem,
        preferredFormat: HLSDecodedAudioConfiguration,
        position: HLSAudioMixProcessingPosition = .postEffects,
        callbacks: HLSAudioMixProcessingCallbacks
    ) throws(HLSAudioMixProcessingError) {
        guard playerItem.audioMix == nil else {
            throw .audioMixAlreadyConfigured
        }

        let storage = HLSAudioMixProcessingStorage(callbacks: callbacks)
        var systemCallbacks = Self.makeCallbacks(storage: storage)
        var createdTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreateWithPreferredFormat(
            kCFAllocatorDefault,
            &systemCallbacks,
            position.creationFlags,
            preferredFormat.requestedAudioFormat,
            &createdTap
        )
        guard status == noErr, let createdTap else {
            throw .tapCreationFailed(status: status)
        }

        let parameters = AVMutableAudioMixInputParameters()
        // The version 27 AVAudioMixInputParametersTrackMixID constant is not
        // imported into Swift. Its documented raw value selects all tracks.
        parameters.trackID = 0
        parameters.audioTapProcessor = createdTap
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]

        playerItem.audioMix = audioMix
        self.playerItem = playerItem
        self.processingTap = createdTap
        self.audioMix = playerItem.audioMix ?? audioMix
    }

    isolated deinit {
        if isAttached,
            Self.contains(processingTap, in: playerItem.audioMix)
        {
            playerItem.audioMix = nil
        }
    }

    /// Detaches this tap without disturbing a replacement audio mix.
    ///
    /// Detachment is idempotent and terminal. Create a new tap to resume
    /// processing.
    public func detach() {
        guard isAttached else { return }
        if Self.contains(processingTap, in: playerItem.audioMix) {
            playerItem.audioMix = nil
        }
        isAttached = false
    }

    private static func contains(
        _ tap: MTAudioProcessingTap,
        in audioMix: AVAudioMix?
    ) -> Bool {
        audioMix?.inputParameters.contains { parameters in
            parameters.audioTapProcessor === tap
        } == true
    }

    private static func makeCallbacks(
        storage: HLSAudioMixProcessingStorage
    ) -> MTAudioProcessingTapCallbacks {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(storage).toOpaque(),
            init: nil,
            finalize: nil,
            prepare: nil,
            unprepare: nil,
            process: { tap, numberFrames, _, bufferList, framesOut, flagsOut in
                HLSAudioMixProcessingBridge.process(
                    tap: tap,
                    numberFrames: numberFrames,
                    bufferList: bufferList,
                    framesOut: framesOut,
                    flagsOut: flagsOut
                )
            }
        )
        callbacks.`init` = { _, clientInfo, storageOut in
            guard let clientInfo else { return }
            storageOut.pointee = clientInfo
            _ = Unmanaged<HLSAudioMixProcessingStorage>
                .fromOpaque(clientInfo)
                .retain()
        }
        callbacks.finalize = { tap in
            let pointer = MTAudioProcessingTapGetStorage(tap)
            Unmanaged<HLSAudioMixProcessingStorage>
                .fromOpaque(pointer)
                .release()
        }
        callbacks.prepare = { tap, maximumFrames, format in
            let storage = HLSAudioMixProcessingBridge.storage(for: tap)
            storage.processingFormat = format.pointee
            storage.callbacks.prepare?(
                HLSAudioMixPreparationContext(
                    maximumFrameCount: maximumFrames,
                    processingFormat: format.pointee
                )
            )
        }
        callbacks.unprepare = { tap in
            let storage = HLSAudioMixProcessingBridge.storage(for: tap)
            storage.callbacks.unprepare?()
            storage.processingFormat = nil
        }
        return callbacks
    }
}

private final class HLSAudioMixProcessingStorage {
    let callbacks: HLSAudioMixProcessingCallbacks

    // MediaToolbox calls process only after prepare returns and stops it before
    // unprepare. Keep this callback-owned state lock-free for the audio thread.
    var processingFormat: AudioStreamBasicDescription?

    init(callbacks: HLSAudioMixProcessingCallbacks) {
        self.callbacks = callbacks
    }
}

private enum HLSAudioMixProcessingBridge {
    static func storage(
        for tap: MTAudioProcessingTap
    ) -> HLSAudioMixProcessingStorage {
        Unmanaged<HLSAudioMixProcessingStorage>
            .fromOpaque(MTAudioProcessingTapGetStorage(tap))
            .takeUnretainedValue()
    }

    static func process(
        tap: MTAudioProcessingTap,
        numberFrames: Int,
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        framesOut: UnsafeMutablePointer<Int>,
        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
    ) {
        var sourceFlags: MTAudioProcessingTapFlags = 0
        var sourceTimeRange = CMTimeRange.invalid
        var sourceFrames = 0
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferList,
            &sourceFlags,
            &sourceTimeRange,
            &sourceFrames
        )
        framesOut.pointee = status == noErr ? sourceFrames : 0
        flagsOut.pointee = sourceFlags
        guard status == noErr, sourceFrames > 0 else {
            return
        }

        let storage = storage(for: tap)
        guard let processingFormat = storage.processingFormat else {
            framesOut.pointee = 0
            return
        }
        storage.callbacks.process(
            UnsafeMutableAudioBufferListPointer(bufferList),
            HLSAudioMixProcessingContext(
                frameCount: sourceFrames,
                streamFlags: HLSAudioMixStreamFlags(rawValue: sourceFlags),
                timeRange: sourceTimeRange,
                processingFormat: processingFormat
            )
        )
    }
}

private extension HLSAudioMixProcessingPosition {
    var creationFlags: MTAudioProcessingTapCreationFlags {
        switch self {
        case .preEffects:
            kMTAudioProcessingTapCreationFlag_PreEffects
        case .postEffects:
            kMTAudioProcessingTapCreationFlag_PostEffects
        }
    }
}
#endif
