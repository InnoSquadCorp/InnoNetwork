import Foundation
import InnoNetwork

public enum WebSocketEvent: Sendable {
    case connected(String?)
    case disconnected(WebSocketError?)
    case message(Data)
    case string(String)
    /// Emitted just before a ping frame is issued, from either the heartbeat
    /// loop or ``WebSocketManager/ping(_:)``.
    ///
    /// A successful ping is followed by `.pong`. Public
    /// ``WebSocketManager/ping(_:)`` failures publish a paired `.error(_:)`
    /// before throwing. Heartbeat timeouts publish `.error(.pingTimeout)`,
    /// while non-timeout transport failures surface through the surrounding
    /// disconnect / error lifecycle.
    ///
    /// The associated ``WebSocketPingContext`` carries the attempt number
    /// within the current connection plus a dispatch timestamp, letting
    /// consumers compute per-cycle RTT without maintaining their own
    /// bookkeeping.
    case ping(WebSocketPingContext)
    /// Emitted when a ping frame's paired pong is received.
    ///
    /// The associated ``WebSocketPongContext`` carries the matching
    /// ``WebSocketPingContext/attemptNumber`` and the library-computed
    /// `roundTrip: Duration`. Consumers can observe this either through the
    /// event stream (pattern-bind the context) or through the convenience
    /// callback ``WebSocketManager/setOnPongHandler(_:)``; **both paths
    /// receive the same `WebSocketPongContext` value** at the same logical
    /// point in the heartbeat / public-ping cycle.
    case pong(WebSocketPongContext)
    case error(WebSocketError)
    /// Emitted when a `send(_:message:)` / `send(_:string:)` call is dropped
    /// because the per-task in-flight count is at
    /// ``WebSocketConfiguration/sendQueueLimit`` and the configured
    /// ``WebSocketSendOverflowPolicy`` is ``WebSocketSendOverflowPolicy/dropNewest``.
    /// Drops do not throw; observers can use this event to surface back-
    /// pressure or report telemetry.
    case sendDropped(limit: Int)
}


/// Metadata that accompanies every ``WebSocketEvent/ping(_:)`` emission.
///
/// - ``attemptNumber`` is a monotonically increasing counter that starts at
///   1 for the first ping of a given connection (heartbeat or public
///   ``WebSocketManager/ping(_:)``) and resets to 0 when a new connection
///   becomes ready or the task is manually reset. Use it to correlate
///   `.ping(_:)` with the paired `.pong` or `.error(_:)` that follow.
/// - ``dispatchedAt`` is captured with `ContinuousClock.now` immediately
///   before the `.ping` event is published. Consumers typically pair it with
///   a `ContinuousClock.now` snapshot at `.pong` receipt to compute RTT.
///
/// This struct is designed to gain fields in minor releases without breaking
/// existing consumers — the public initializer is package-scoped so the
/// library controls construction.
public struct WebSocketPingContext: Sendable, Hashable {
    /// Sequence number of this ping attempt within the current connection.
    /// 1-indexed; resets when a new connection becomes ready or on task reset.
    public let attemptNumber: Int

    /// `ContinuousClock.now` snapshot at the moment `.ping(_:)` is
    /// published, captured immediately before the actual ping frame is
    /// dispatched.
    public let dispatchedAt: ContinuousClock.Instant

    package init(attemptNumber: Int, dispatchedAt: ContinuousClock.Instant) {
        self.attemptNumber = attemptNumber
        self.dispatchedAt = dispatchedAt
    }
}


/// Metadata delivered to ``WebSocketManager/setOnPongHandler(_:)`` for each
/// successful pong observation.
///
/// - ``attemptNumber`` matches the ``WebSocketPingContext/attemptNumber``
///   of the paired ping, so consumers can correlate ping/pong pairs
///   without bookkeeping a timestamp map keyed on the ping dispatch time.
/// - ``roundTrip`` is the library-computed duration between the
///   `.ping(_:)` event emission and the pong handler callback. It is measured
///   as `ContinuousClock.now - pingContext.dispatchedAt` just before the
///   `.pong` event is published, so it includes the library's own ping-send +
///   pong-handler dispatch but excludes consumer-side scheduler jitter.
///   Heartbeat scheduling still uses the injected `InnoNetworkClock`; RTT
///   measurement always uses wall-clock `ContinuousClock`.
///
/// This struct is designed to gain fields in minor releases without
/// breaking existing consumers — the public initializer is package-scoped
/// so the library controls construction.
public struct WebSocketPongContext: Sendable, Hashable {
    /// Sequence number of the paired ping attempt. Matches the
    /// `.ping(_:)` event's ``WebSocketPingContext/attemptNumber``.
    public let attemptNumber: Int

    /// Elapsed time between the paired `.ping(_:)` dispatch and this
    /// pong-handler callback, computed as
    /// `ContinuousClock.now - pingContext.dispatchedAt`. This value is not
    /// derived from the injected heartbeat scheduling clock.
    public let roundTrip: Duration

    package init(attemptNumber: Int, roundTrip: Duration) {
        self.attemptNumber = attemptNumber
        self.roundTrip = roundTrip
    }
}

public struct WebSocketEventSubscription: Hashable, Sendable {
    let taskId: String
    let listenerID: UUID

    public var id: UUID { listenerID }
}

enum WebSocketInternalError: Error {
    case pingTimeout
}
