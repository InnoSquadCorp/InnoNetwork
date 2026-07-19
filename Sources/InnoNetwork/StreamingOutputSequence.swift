import Foundation

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
/// The sequence wraps the executor-owned `AsyncThrowingStream`, whose
/// construction the standard library constrains to an untyped failure. Every
/// failure the executor finishes that stream with is a ``NetworkError`` by
/// construction (pinned by the streaming test suite); if a foreign error
/// ever escaped that invariant it would surface here mapped through
/// ``NetworkError``'s transport-error taxonomy rather than trapping.
public struct StreamingOutputSequence<Output: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Output

    private let base: AsyncThrowingStream<Output, Error>

    package init(base: AsyncThrowingStream<Output, Error>) {
        self.base = base
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var base: AsyncThrowingStream<Output, Error>.Iterator

        fileprivate init(base: AsyncThrowingStream<Output, Error>.Iterator) {
            self.base = base
        }

        public mutating func next() async throws(NetworkError) -> Output? {
            do {
                return try await base.next()
            } catch {
                throw Self.normalized(error)
            }
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        public mutating func next(
            isolation actor: isolated (any Actor)?
        ) async throws(NetworkError) -> Output? {
            do {
                return try await base.next(isolation: actor)
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
