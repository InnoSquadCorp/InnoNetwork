import AVFoundation
import Foundation

/// Observes allowlisted HLS timed metadata on one caller-owned player item.
///
/// The monitor uses `AVPlayerItemMetadataOutput`; it never reads the
/// deprecated `AVPlayerItem.timedMetadata` property. Retain this object for
/// the desired observation lifetime and call ``detach()`` when observation
/// should end before deallocation.
@MainActor
public final class HLSTimedMetadataMonitor {
    private let playerItem: AVPlayerItem
    private let output: AVPlayerItemMetadataOutput
    private let retainedDelegate: HLSTimedMetadataDelegate
    private let eventHub: HLSTimedMetadataEventHub
    private let maximumBufferedEventCount: Int

    /// Whether the system metadata output is attached to the player item.
    public private(set) var isAttached = true

    /// Creates and attaches an allowlisted timed-metadata output.
    ///
    /// Each call to ``events()`` creates an independent bounded subscriber.
    /// Slow subscribers retain the newest configured number of events. An
    /// empty field list is rejected before the native output is created and
    /// is never converted to AVFoundation's `nil` "receive all" behavior.
    public init(
        playerItem: AVPlayerItem,
        configuration: HLSTimedMetadataConfiguration
    ) throws(HLSTimedMetadataError) {
        guard !configuration.fields.isEmpty else {
            throw .emptyIdentifierAllowlist
        }
        let eventHub = HLSTimedMetadataEventHub()
        let delegate = HLSTimedMetadataDelegate(
            configuration: configuration,
            eventHub: eventHub
        )
        let output = AVPlayerItemMetadataOutput(
            identifiers: configuration.fields.map {
                $0.identifier.rawValue
            }
        )
        output.advanceIntervalForDelegateInvocation =
            configuration.advanceInterval
        output.setDelegate(delegate, queue: delegate.queue)

        self.playerItem = playerItem
        self.output = output
        self.retainedDelegate = delegate
        self.eventHub = eventHub
        self.maximumBufferedEventCount =
            configuration.maximumBufferedEventCount
        playerItem.add(output)
    }

    deinit {
        if isAttached {
            output.setDelegate(nil, queue: nil)
            playerItem.remove(output)
            retainedDelegate.finish()
        }
    }

    /// Starts an independent bounded event stream.
    ///
    /// The stream finishes normally after ``detach()`` or monitor
    /// deallocation. Cancellation removes only that subscriber.
    public func events() -> AsyncStream<HLSTimedMetadataEvent> {
        eventHub.events(
            maximumBufferedEventCount: maximumBufferedEventCount
        )
    }

    /// Detaches the system output and finishes every active event stream.
    ///
    /// Detachment is idempotent and terminal. Create a new monitor to resume
    /// timed-metadata delivery.
    public func detach() {
        guard isAttached else {
            return
        }
        output.setDelegate(nil, queue: nil)
        playerItem.remove(output)
        retainedDelegate.finish()
        isAttached = false
    }
}
