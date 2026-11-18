import Foundation

// MARK: - Operation handles on the client itself

extension NetworkClient {
    /// Starts a typed request and immediately returns its operation handle.
    ///
    /// The handle exposes the same execution as `request(_:tag:)` —
    /// interceptors, authentication, retry, cache, and decoding are unchanged
    /// — and adds cancellation without retaining the client, a bounded
    /// lifecycle event stream, and an optional end-to-end deadline.
    ///
    /// ```swift
    /// let operation = client.start(GetUser(id: 1), deadline: .init(after: .seconds(10)))
    /// let user = try await operation.value()
    /// ```
    ///
    /// - Parameters:
    ///   - request: The endpoint to execute.
    ///   - replaySafety: Whether a restart may repeat the request. It affects
    ///     only the recovery recommendation in
    ///     ``NetworkOperationEvent/failed(id:summary:)``. Use
    ///     ``NetworkOperationReplaySafety/stableIdempotencyKey`` only when the
    ///     application reuses the same idempotency key across newly created
    ///     operation handles.
    ///   - deadline: One monotonic latency budget for the whole operation.
    public func start<Request: APIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil
    ) -> NetworkOperation<Request.APIResponse> {
        start(request, replaySafety: replaySafety, deadline: deadline, deadlineClock: SystemClock())
    }

    /// Clock seam for the package's own deadline tests.
    package func start<Request: APIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil,
        deadlineClock: any InnoNetworkClock
    ) -> NetworkOperation<Request.APIResponse> {
        NetworkOperationRunner.start(
            method: request.method,
            authentication: request.sessionAuthentication,
            replaySafety: replaySafety,
            deadline: deadline,
            deadlineClock: deadlineClock
        ) { [self] tag async throws(NetworkError) in
            try await self.request(request, tag: tag)
        }
    }
}

extension UploadNetworkClient {
    /// Starts a multipart upload and immediately returns its operation handle.
    ///
    /// The handle exposes the same execution as ``upload(_:tag:)`` and adds
    /// cancellation, lifecycle events, and an optional end-to-end deadline.
    ///
    /// - Parameters:
    ///   - request: The multipart endpoint to execute.
    ///   - replaySafety: Whether a restart may repeat the upload. Like the
    ///     same argument of `start(_:replaySafety:deadline:)`, it affects only
    ///     the recovery recommendation in
    ///     ``NetworkOperationEvent/failed(id:summary:)``; it never makes the
    ///     client retry.
    ///   - deadline: One monotonic latency budget for the whole operation.
    public func startUpload<Request: MultipartAPIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil
    ) -> NetworkOperation<Request.APIResponse> {
        startUpload(request, replaySafety: replaySafety, deadline: deadline, deadlineClock: SystemClock())
    }

    /// Clock seam for the package's own deadline tests.
    package func startUpload<Request: MultipartAPIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil,
        deadlineClock: any InnoNetworkClock
    ) -> NetworkOperation<Request.APIResponse> {
        NetworkOperationRunner.start(
            method: request.method,
            authentication: request.sessionAuthentication,
            replaySafety: replaySafety,
            deadline: deadline,
            deadlineClock: deadlineClock
        ) { [self] tag async throws(NetworkError) in
            try await self.upload(request, tag: tag)
        }
    }
}

extension EncodedRequestClient {
    /// Starts a custom-codec request using the same operation lifecycle and
    /// deadline gate as a typed request.
    public func start<Output: Sendable>(
        _ request: EncodedRequest<Output>,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil
    ) -> NetworkOperation<Output> {
        start(request, replaySafety: replaySafety, deadline: deadline, deadlineClock: SystemClock())
    }

    /// Clock seam for the package's own deadline tests.
    package func start<Output: Sendable>(
        _ request: EncodedRequest<Output>,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil,
        deadlineClock: any InnoNetworkClock
    ) -> NetworkOperation<Output> {
        NetworkOperationRunner.start(
            method: request.method,
            authentication: request.sessionAuthentication,
            replaySafety: replaySafety,
            deadline: deadline,
            deadlineClock: deadlineClock
        ) { [self] tag async throws(NetworkError) in
            try await self.request(request, tag: tag)
        }
    }

    /// Starts a named binary endpoint. Preparation failures are delivered
    /// through the handle, after the cancellation and deadline admission
    /// checks.
    public func start<Definition: EncodedAPIDefinition>(
        _ definition: Definition,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil
    ) -> NetworkOperation<Definition.APIResponse> {
        start(definition, replaySafety: replaySafety, deadline: deadline, deadlineClock: SystemClock())
    }

    /// Clock seam for the package's own deadline tests.
    package func start<Definition: EncodedAPIDefinition>(
        _ definition: Definition,
        replaySafety: NetworkOperationReplaySafety = .methodDefault,
        deadline: NetworkOperationDeadline? = nil,
        deadlineClock: any InnoNetworkClock
    ) -> NetworkOperation<Definition.APIResponse> {
        let metadata = EncodedDefinitionMetadata(definition)
        return NetworkOperationRunner.start(
            method: metadata.method,
            authentication: metadata.authentication,
            replaySafety: replaySafety,
            deadline: deadline,
            deadlineClock: deadlineClock
        ) { [self] tag async throws(NetworkError) in
            let request = try metadata.prepare(definition)
            return try await self.request(request, tag: tag)
        }
    }
}

// MARK: - Shared lifecycle

/// Runs one client call as a ``NetworkOperation``: registers the lifecycle
/// stream, enforces the optional deadline, forwards cancellation, and
/// normalizes every failure to ``NetworkError``.
package enum NetworkOperationRunner {
    package static func start<Output: Sendable>(
        method: HTTPMethod,
        authentication: SessionAuthentication,
        replaySafety: NetworkOperationReplaySafety,
        deadline: NetworkOperationDeadline?,
        deadlineClock: any InnoNetworkClock,
        execute: @escaping @Sendable (CancellationTag) async throws(NetworkError) -> Output
    ) -> NetworkOperation<Output> {
        let id = UUID()
        let tag = CancellationTag(id.uuidString)
        let (events, continuation) = AsyncStream<NetworkOperationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let deadlineBudget = deadline.map {
            TimingBudget(duration: $0.duration, startedAt: deadlineClock.monotonicNow())
        }

        @Sendable func finish(
            _ result: Result<Output, NetworkError>
        ) -> Result<Output, NetworkOperationFailure> {
            defer { continuation.finish() }
            switch result {
            case .success(let value):
                continuation.yield(.succeeded(id: id))
                return .success(value)
            case .failure(let error):
                let summary = error.summary(
                    method: method,
                    authentication: authentication,
                    replaySafety: replaySafety
                )
                continuation.yield(.failed(id: id, summary: summary))
                return .failure(NetworkOperationFailure(error: error, summary: summary))
            }
        }

        let task = Task<Result<Output, NetworkOperationFailure>, Never> {
            continuation.yield(.started(id: id))
            let tracker = NetworkOperationDeadlineTracker()
            tracker.mark(.requestPreparation)

            @Sendable func deadlineExceeded() -> NetworkError {
                .timeout(reason: .operationDeadline(tracker.currentStage), underlying: nil)
            }

            if Task.isCancelled {
                return finish(.failure(.cancelled))
            }
            if let deadlineBudget, deadlineBudget.isExpired(at: deadlineClock.monotonicNow()) {
                return finish(.failure(deadlineExceeded()))
            }

            let gate = NetworkOperationResultGate<Output>()
            let requestTask = Task<Void, Never> {
                let result: Result<Output, NetworkError> = await NetworkOperationDeadlineContext.$tracker
                    .withValue(tracker) {
                        do throws(NetworkError) {
                            return .success(try await execute(tag))
                        } catch {
                            return .failure(error)
                        }
                    }
                if let deadlineBudget, deadlineBudget.isExpired(at: deadlineClock.monotonicNow()) {
                    gate.resolve(.failure(deadlineExceeded()))
                } else {
                    gate.resolve(result)
                }
            }

            let deadlineTask: Task<Void, Never>?
            if let deadlineBudget {
                deadlineTask = Task {
                    do {
                        try await deadlineBudget.sleep(using: deadlineClock)
                    } catch {
                        // The operation finished or was cancelled first.
                        return
                    }
                    if gate.resolve(.failure(deadlineExceeded())) {
                        requestTask.cancel()
                    }
                }
            } else {
                deadlineTask = nil
            }

            let result = await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                requestTask.cancel()
                deadlineTask?.cancel()
                gate.resolve(.failure(.cancelled))
            }
            deadlineTask?.cancel()
            requestTask.cancel()
            return finish(result)
        }
        return NetworkOperation(id: id, events: events, task: task)
    }
}
