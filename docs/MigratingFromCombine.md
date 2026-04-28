# Migrating from Combine

InnoNetwork is async/await-native by design. The library does **not** import
or re-export Combine, and there is no `Future` / `AnyPublisher` overload
sitting on top of `NetworkClient`. This document is for code bases that
still use Combine internally and want a straight, non-disruptive path to
adopt InnoNetwork.

If you are starting fresh, prefer `try await client.request(...)` directly
and ignore this page.

## TL;DR — three migration paths

| Situation | Recommended path |
|---|---|
| You can refactor the call site | Replace the publisher with `Task { try await ... }` and `for await ...` consumption. |
| You can refactor only the boundary | Add a one-line `Future` adapter (below) and keep the rest of the Combine pipeline untouched. |
| You cannot refactor anything yet | Wrap the call in a closure-based shim that exposes `(Result<T, Error>) -> Void` so `Future` is built upstream. |

All three paths leave InnoNetwork itself unchanged — only the calling code
moves.

## Path 1 — Refactor the call site (recommended)

Combine pipeline:

```swift
client.requestPublisher(GetUser(id: id))
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { [weak self] completion in
            if case .failure(let error) = completion {
                self?.show(error: error)
            }
        },
        receiveValue: { [weak self] user in
            self?.user = user
        }
    )
    .store(in: &cancellables)
```

Async equivalent:

```swift
Task { @MainActor [weak self] in
    do {
        let user = try await client.request(GetUser(id: id))
        self?.user = user
    } catch {
        self?.show(error: error)
    }
}
```

Cancellation: Combine's `AnyCancellable.cancel()` becomes
`Task.cancel()`. InnoNetwork forwards outer-task cancellation through
the request pipeline and surfaces `NetworkError.cancelled`.

`receive(on: DispatchQueue.main)` is replaced by `@MainActor` on the
closure (or by the SwiftUI view consuming the `@Published` value).

Storing tasks: hold the `Task` in a property if you need to cancel it
later. For a simple "fire and forget on view appear" pattern, you can
also use `.task { ... }` from SwiftUI, which cancels automatically when
the view disappears.

## Path 2 — Adapter at the boundary

When the rest of the Combine pipeline (debounce, combineLatest, custom
operators) is too valuable to rewrite right now, keep it in place and
add a one-shot adapter that turns `async throws -> T` into a
`Future<T, Error>` publisher.

The adapter belongs in the **consumer** code, not in InnoNetwork itself,
so the library stays Combine-free:

```swift
import Combine
import InnoNetwork

extension NetworkClient {
    /// Bridges ``request(_:)`` to a `Future` so existing Combine pipelines
    /// can consume the response without rewriting their operator chain.
    /// The bridge intentionally lives in consumer code; InnoNetwork itself
    /// does not depend on Combine.
    public func requestPublisher<T: APIDefinition>(
        _ request: T
    ) -> AnyPublisher<T.APIResponse, Error> {
        Future { promise in
            Task {
                do {
                    promise(.success(try await self.request(request)))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }
}
```

Caveats to be aware of:

- **Cancellation does not flow back to the Task.** When the downstream
  `AnyCancellable` is dropped, the `Future` stops emitting, but the
  underlying `Task` continues to completion. For long-running requests,
  prefer the Path 1 rewrite or capture and cancel the `Task` in
  `handleEvents(receiveCancel:)`.
- **The `Future` runs the work eagerly** because `Task { ... }` is
  unstructured. Wrap in `Deferred { Future { ... } }` if you need lazy
  execution.

## Path 3 — Closure shim

When you cannot touch either side of the call right now, expose a
closure-based seam and let upstream code build the publisher:

```swift
public func loadUser(
    id: Int,
    completion: @escaping @Sendable (Result<User, Error>) -> Void
) {
    Task {
        do {
            completion(.success(try await client.request(GetUser(id: id))))
        } catch {
            completion(.failure(error))
        }
    }
}
```

Upstream Combine code can wrap that with `Future` exactly the same way
it wraps `URLSession.shared.dataTaskPublisher(for:)`. This keeps
InnoNetwork out of the Combine import graph entirely.

## Streaming endpoints

`StreamingAPIDefinition` returns `AsyncThrowingStream`, which has no
direct `Publisher` analogue. Two options:

1. **Recommended:** consume with `for await`:
   ```swift
   for try await event in try await client.stream(MyStream()) {
       handle(event)
   }
   ```
2. **Bridge to a `PassthroughSubject`:** spawn a `Task` that pumps the
   stream into the subject and forwards termination through `send(completion:)`.
   This is structurally identical to Path 2 and inherits the same
   cancellation caveat.

## What you should *not* do

- Do not add a `Combine` dependency to InnoNetwork. The library targets
  Apple platforms but stays focused on Swift Concurrency primitives;
  pulling Combine in would broaden the public surface area for no
  payoff.
- Do not wrap every endpoint with a `requestPublisher` overload as a
  permanent setup. The adapter is a migration aid, not an end state —
  it loses cancellation propagation and adds a layer that is invisible
  in stack traces.
- Do not chain `Future` calls to compose multiple requests. Use
  `async let` or `withThrowingTaskGroup`; the result is shorter and
  cancels correctly.
