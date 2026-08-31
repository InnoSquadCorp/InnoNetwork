import AVFoundation
import CoreAudioTypes
import CoreMedia
import Foundation

/// Failures raised while configuring or consuming decoded HLS audio.
public enum HLSDecodedAudioError: Error, Equatable, Sendable {
    /// The requested output format is not linear PCM audio.
    case requestedFormatMustBeLinearPCM

    /// The requested sample rate is not finite and greater than zero.
    case invalidSampleRate

    /// The requested channel count is zero.
    case invalidChannelCount

    /// AVFoundation could not create the requested linear PCM format.
    case formatCreationFailed

    /// The output has already been detached from its player item.
    case outputDetached

    /// Another read is already waiting for the next sample.
    case readAlreadyInProgress
}

extension HLSDecodedAudioError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestedFormatMustBeLinearPCM:
            "The requested decoded-audio format must be linear PCM."
        case .invalidSampleRate:
            "The decoded-audio sample rate must be finite and greater than zero."
        case .invalidChannelCount:
            "The decoded-audio channel count must be greater than zero."
        case .formatCreationFailed:
            "AVFoundation could not create the requested decoded-audio format."
        case .outputDetached:
            "The decoded-audio output is detached from its player item."
        case .readAlreadyInProgress:
            "Another decoded-audio read is already in progress."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .requestedFormatMustBeLinearPCM:
            "Pass a linear PCM CMAudioFormatDescription."
        case .invalidSampleRate:
            "Choose a finite positive sample rate, such as 48,000 Hz."
        case .invalidChannelCount:
            "Choose at least one audio channel."
        case .formatCreationFailed:
            "Choose a sample rate and channel count supported by AVAudioFormat."
        case .outputDetached:
            "Create a new HLSDecodedAudioOutput for the player item."
        case .readAlreadyInProgress:
            "Wait for or cancel the active read before starting another one."
        }
    }
}

/// The decoded PCM format requested from AVFoundation.
@available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
public struct HLSDecodedAudioConfiguration: Sendable {
    /// The requested linear PCM audio format.
    ///
    /// AVFoundation may vary the numeric representation, interleaving, or
    /// sample size. Inspect each delivered sample buffer's format description
    /// before binding it to a processing pipeline.
    public let requestedAudioFormat: CMAudioFormatDescription

    /// Creates a configuration from a linear PCM format description.
    public init(
        requestedAudioFormat: CMAudioFormatDescription
    ) throws(HLSDecodedAudioError) {
        guard Self.isLinearPCM(requestedAudioFormat) else {
            throw .requestedFormatMustBeLinearPCM
        }
        guard
            let streamDescription =
                CMAudioFormatDescriptionGetStreamBasicDescription(
                    requestedAudioFormat
                )?.pointee
        else {
            throw .requestedFormatMustBeLinearPCM
        }
        guard
            streamDescription.mSampleRate.isFinite,
            streamDescription.mSampleRate > 0
        else {
            throw .invalidSampleRate
        }
        guard streamDescription.mChannelsPerFrame > 0 else {
            throw .invalidChannelCount
        }
        self.requestedAudioFormat = requestedAudioFormat
    }

    /// Creates a Float32 linear PCM configuration.
    ///
    /// Non-interleaved Float32 is a practical default for waveform, level,
    /// speech, and navigation-assistance processing. The request does not
    /// guarantee that AVFoundation will deliver an identical memory layout.
    public static func float32(
        sampleRate: Double = 48_000,
        channelCount: AVAudioChannelCount = 2,
        interleaved: Bool = false
    ) throws(HLSDecodedAudioError) -> Self {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidSampleRate
        }
        guard channelCount > 0 else {
            throw .invalidChannelCount
        }
        guard
            let audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: interleaved
            )
        else {
            throw .formatCreationFailed
        }
        return try Self(
            requestedAudioFormat: audioFormat.formatDescription
        )
    }

    package static func isLinearPCM(
        _ formatDescription: CMAudioFormatDescription
    ) -> Bool {
        CMFormatDescriptionGetMediaType(formatDescription)
            == kCMMediaType_Audio
            && CMFormatDescriptionGetMediaSubType(formatDescription)
                == kAudioFormatLinearPCM
            && CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            )?.pointee.mFormatID == kAudioFormatLinearPCM
    }
}
