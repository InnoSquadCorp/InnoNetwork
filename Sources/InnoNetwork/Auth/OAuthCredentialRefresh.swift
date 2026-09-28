import Foundation
import os

/// Lives in one RequestSecurity configuration, never in a global token cache.
/// Only in-flight results are retained. A cancelled waiter cannot cancel peers;
/// the last waiter cancels the provider task and removes the entry immediately.
actor OAuthCredentialRefreshCoordinator {
    private struct Key: Hashable {
        let scheme: String
        let scopes: [String]
        let realm: String
        let principal: String
    }

    private struct Waiter {
        let continuation: CheckedContinuation<RequestSecurity.Credential, Error>
        let cancelled: OSAllocatedUnfairLock<Bool>
    }

    private struct Entry {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter]
    }

    private var entries: [Key: Entry] = [:]
    var inFlightWaiterCount: Int { entries.values.reduce(0) { $0 + $1.waiters.count } }

    func refresh(
        scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection,
        operation: @escaping @Sendable () async throws -> RequestSecurity.Credential
    ) async throws -> RequestSecurity.Credential {
        guard case .oauth2(let id, let scopes) = scheme else {
            throw RequestSecurityFailure.invalidRequirements.networkError
        }
        let key = Key(scheme: id, scopes: scopes.sorted(), realm: selection.realm, principal: selection.principal)
        let waiterID = UUID()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let credential: RequestSecurity.Credential = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RequestSecurity.Credential, Error>) in
                guard !Task.isCancelled, !cancelled.withLock({ $0 }) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(continuation: continuation, cancelled: cancelled)
                if var entry = entries[key] {
                    guard entry.waiters.count < 128 else {
                        continuation.resume(throwing: RequestSecurityFailure.refreshFailed.networkError)
                        return
                    }
                    entry.waiters[waiterID] = waiter
                    entries[key] = entry
                } else {
                    guard entries.count < 64 else {
                        continuation.resume(throwing: RequestSecurityFailure.refreshFailed.networkError)
                        return
                    }
                    let entryID = UUID()
                    entries[key] = Entry(id: entryID, waiters: [waiterID: waiter])
                    entries[key]?.task = Task {
                        let result: Result<RequestSecurity.Credential, Error>
                        do { result = .success(try await operation()) } catch { result = .failure(error) }
                        self.finish(key: key, id: entryID, result: result)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            Task { await self.cancel(key: key, waiter: waiterID) }
        }
        try Task.checkCancellation()
        return credential
    }

    private func finish(key: Key, id: UUID, result: Result<RequestSecurity.Credential, Error>) {
        guard let entry = entries[key], entry.id == id else { return }
        entries[key] = nil
        for waiter in entry.waiters.values {
            if waiter.cancelled.withLock({ $0 }) {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                waiter.continuation.resume(with: result)
            }
        }
    }

    private func cancel(key: Key, waiter id: UUID) {
        guard var entry = entries[key], let waiter = entry.waiters.removeValue(forKey: id) else { return }
        if entry.waiters.isEmpty {
            entries[key] = nil
            entry.task?.cancel()
        } else {
            entries[key] = entry
        }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// Deliberately accepts one bounded Bearer auth-param challenge. Ambiguous or
/// combined challenges do not trigger renewal. Never substring-match quoted text.
enum OAuthBearerChallenge {
    static func error(in header: String?) -> String? {
        guard let header, header.utf8.count <= 8192,
            header.utf8.allSatisfy({ (32...126).contains($0) || $0 == 9 })
        else { return nil }
        let bytes = Array(header.utf8)
        var index = 0
        func whitespace() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
        }
        func token() -> String? {
            let start = index
            while index < bytes.count,
                RequestSecurity.validToken(String(UnicodeScalar(bytes[index])))
            { index += 1 }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        whitespace()
        guard token()?.lowercased() == "bearer", index < bytes.count, bytes[index] == 32 || bytes[index] == 9 else {
            return nil
        }
        whitespace()
        var parameters: [String: String] = [:]
        while index < bytes.count {
            guard parameters.count < 32, let name = token()?.lowercased() else { return nil }
            whitespace()
            guard index < bytes.count, bytes[index] == 61 else { return nil }
            index += 1
            whitespace()
            let value: String
            if index < bytes.count, bytes[index] == 34 {
                index += 1
                var content: [UInt8] = []
                var closed = false
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 34 {
                        closed = true
                        break
                    }
                    if byte == 92 {
                        guard index < bytes.count else { return nil }
                        content.append(bytes[index])
                        index += 1
                    } else {
                        content.append(byte)
                    }
                }
                guard closed else { return nil }
                value = String(decoding: content, as: UTF8.self)
            } else {
                guard let parsed = token() else { return nil }
                value = parsed
            }
            guard parameters.updateValue(value, forKey: name) == nil else { return nil }
            whitespace()
            if index == bytes.count { break }
            guard bytes[index] == 44 else { return nil }
            index += 1
            whitespace()
            guard index < bytes.count else { return nil }
        }
        return parameters["error"]
    }
}
