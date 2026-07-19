import Foundation
import os

package enum StreamingOutputBuffering: Sendable {
    case backpressured
    case unbounded
    case bufferingNewest(Int)
    case bufferingOldest(Int)

    package init(_ policy: StreamingBufferingPolicy) {
        switch policy {
        case .unbounded:
            self = .unbounded
        case .bufferingNewest(let limit):
            self = .bufferingNewest(limit)
        case .bufferingOldest(let limit):
            self = .bufferingOldest(limit)
        }
    }

    fileprivate var appliesBackpressure: Bool {
        if case .backpressured = self { return true }
        return false
    }
}

private final class StreamingOutputAcknowledgement: Sendable {
    private struct State {
        var waiter: CheckedContinuation<Void, Never>?
        var isReleased = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async -> Bool {
        guard !Task.isCancelled else {
            release()
            return false
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = state.withLock { state in
                    if state.isReleased {
                        return true
                    }
                    precondition(state.waiter == nil, "Streaming output acknowledgement may only have one waiter")
                    state.waiter = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            release()
        }
        return !Task.isCancelled
    }

    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.isReleased else { return nil }
            state.isReleased = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

package struct StreamingOutputDelivery<Output: Sendable>: Sendable {
    package let output: Output
    private let acknowledgement: StreamingOutputAcknowledgement?

    fileprivate init(output: Output, acknowledgement: StreamingOutputAcknowledgement?) {
        self.output = output
        self.acknowledgement = acknowledgement
    }

    package func acknowledge() {
        acknowledgement?.release()
    }
}

package struct StreamingOutputSink<Output: Sendable>: Sendable {
    private let continuation: AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>.Continuation
    private let appliesBackpressure: Bool

    fileprivate init(
        continuation: AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>.Continuation,
        appliesBackpressure: Bool
    ) {
        self.continuation = continuation
        self.appliesBackpressure = appliesBackpressure
    }

    package func yield(_ output: Output) async throws(NetworkError) {
        guard !Task.isCancelled else { throw .cancelled }

        let acknowledgement = appliesBackpressure ? StreamingOutputAcknowledgement() : nil
        let delivery = StreamingOutputDelivery(output: output, acknowledgement: acknowledgement)

        switch continuation.yield(delivery) {
        case .enqueued:
            if let acknowledgement, !(await acknowledgement.wait()) {
                throw .cancelled
            }
        case .dropped(let dropped):
            dropped.acknowledge()
            acknowledgement?.release()
            if appliesBackpressure {
                throw .configuration(
                    reason: .invalidRequest("The lossless streaming output channel violated its backpressure bound.")
                )
            }
        case .terminated:
            acknowledgement?.release()
            throw .cancelled
        @unknown default:
            acknowledgement?.release()
            throw .configuration(
                reason: .invalidRequest("The streaming output channel returned an unsupported yield result.")
            )
        }
    }

    package func finish() {
        continuation.finish()
    }

    package func finish(throwing error: NetworkError) {
        continuation.finish(throwing: error)
    }

    package func onTermination(_ handler: @escaping @Sendable () -> Void) {
        let continuation = continuation
        continuation.onTermination = { _ in handler() }
    }
}

/// An asynchronous sequence of decoded streaming payloads whose failure type
/// is ``NetworkError``.
///
/// Returned by ``DefaultNetworkClient/stream(_:)`` and
/// ``DefaultNetworkClient/stream(_:bufferingPolicy:)``. Iterating the
/// concrete sequence throws ``NetworkError`` on every supported platform
/// floor, so a plain `catch` binds the typed error directly and
/// `do throws(NetworkError)` blocks compose without casts:
///
/// ```swift
/// do throws(NetworkError) {
///     for try await event in client.stream(LiveEvents()) {
///         render(event)
///     }
/// } catch {
///     handle(error)  // error is NetworkError
/// }
/// ```
///
/// On iOS 18 / macOS 15 and newer the sequence additionally participates in
/// typed-failure generics (`some AsyncSequence<Output, NetworkError>`) via
/// the standard library's `Failure` primary associated type; older runtimes
/// lack that witness, which is why the conformance leaves `Failure` inferred
/// instead of pinning a typealias the floor cannot ship.
///
/// The default client path applies one-element producer backpressure: the
/// executor does not read and decode another frame until the consumer has
/// removed the previous output from this sequence. Explicit lossy or
/// unbounded policies remain available through
/// ``DefaultNetworkClient/stream(_:bufferingPolicy:)``.
public struct StreamingOutputSequence<Output: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Output

    private let base: AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>

    package static func make(
        buffering: StreamingOutputBuffering
    ) -> (sequence: Self, sink: StreamingOutputSink<Output>) {
        let policy: AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>.Continuation.BufferingPolicy
        switch buffering {
        case .backpressured:
            policy = .bufferingOldest(1)
        case .unbounded:
            policy = .unbounded
        case .bufferingNewest(let limit):
            policy = .bufferingNewest(Swift.max(1, limit))
        case .bufferingOldest(let limit):
            policy = .bufferingOldest(Swift.max(1, limit))
        }
        let (base, continuation) = AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>.makeStream(
            bufferingPolicy: policy
        )
        return (
            Self(base: base),
            StreamingOutputSink(
                continuation: continuation,
                appliesBackpressure: buffering.appliesBackpressure
            )
        )
    }

    package static func failure(_ error: NetworkError) -> Self {
        let (sequence, sink) = make(buffering: .backpressured)
        sink.finish(throwing: error)
        return sequence
    }

    private init(base: AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>) {
        self.base = base
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var base: AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>.Iterator

        fileprivate init(base: AsyncThrowingStream<StreamingOutputDelivery<Output>, Error>.Iterator) {
            self.base = base
        }

        public mutating func next() async throws(NetworkError) -> Output? {
            do {
                guard let delivery = try await base.next() else { return nil }
                delivery.acknowledge()
                return delivery.output
            } catch {
                throw Self.normalized(error)
            }
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        public mutating func next(
            isolation actor: isolated (any Actor)?
        ) async throws(NetworkError) -> Output? {
            do {
                guard let delivery = try await base.next(isolation: actor) else { return nil }
                delivery.acknowledge()
                return delivery.output
            } catch {
                throw Self.normalized(error)
            }
        }

        private static func normalized(_ error: any Error) -> NetworkError {
            if let networkError = error as? NetworkError {
                return networkError
            }
            // Fail closed instead of trapping: the executor invariant is that
            // only NetworkError reaches the underlying stream, so this arm is
            // unreachable in practice but keeps the typed boundary total.
            return NetworkError.mapTransportError(error)
        }
    }
}
