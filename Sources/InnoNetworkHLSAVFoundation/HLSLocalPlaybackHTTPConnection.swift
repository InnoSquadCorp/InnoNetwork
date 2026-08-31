#if canImport(AVFoundation) && canImport(Network)
import Foundation
import Network
import os

final class HLSLocalPlaybackHTTPConnection: Sendable {
    private static let maximumHeaderByteCount = 16 * 1_024
    private static let responseChunkByteCount = 64 * 1_024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let root: HLSLocalPlaybackPackageRoot
    private let token: String
    private let onFinish: @Sendable () -> Void
    private let didFinish = OSAllocatedUnfairLock(
        initialState: false
    )

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        root: HLSLocalPlaybackPackageRoot,
        token: String,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.root = root
        self.token = token
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHeader(Data())
    }

    func cancel() {
        finish()
    }

    private func receiveHeader(_ accumulated: Data) {
        let remaining =
            Self.maximumHeaderByteCount
            - accumulated.count
        guard remaining > 0 else {
            sendError(.badRequest)
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: remaining
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if error != nil {
                finish()
                return
            }
            var header = accumulated
            if let data {
                header.append(data)
            }
            if header.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(to: header)
                return
            }
            if isComplete {
                sendError(.badRequest)
                return
            }
            receiveHeader(header)
        }
    }

    private func respond(to header: Data) {
        do {
            let request = try HLSLocalPlaybackHTTPRequest(
                header: header
            )
            let file = try root.resource(
                requestTarget: request.target,
                token: token
            )
            let range = try request.range.resolve(
                fileSize: file.size
            )
            try send(
                file: file,
                range: range,
                sendsBody: request.method == .get
            )
        } catch let error as HLSLocalPlaybackHTTPError {
            sendError(error)
        } catch {
            sendError(.internalFailure)
        }
    }

    private func send(
        file: HLSLocalPlaybackFile,
        range: HLSLocalPlaybackResolvedRange,
        sendsBody: Bool
    ) throws {
        let header = HLSLocalPlaybackHTTPResponse.successHeader(
            file: file,
            range: range
        )
        guard sendsBody, range.length > 0 else {
            sendAndFinish(header)
            return
        }
        switch file.storage {
        case .data(let data):
            guard let offset = Int(exactly: range.start),
                let length = Int(exactly: range.length)
            else {
                throw HLSLocalPlaybackHTTPError.internalFailure
            }
            connection.send(
                content: header,
                completion: .contentProcessed { [weak self] error in
                    guard let self else {
                        return
                    }
                    guard error == nil else {
                        finish()
                        return
                    }
                    sendNext(
                        data: data,
                        offset: offset,
                        remaining: length
                    )
                }
            )
        case .file(let url):
            let fileHandle = try FileHandle(forReadingFrom: url)
            try fileHandle.seek(toOffset: UInt64(range.start))
            connection.send(
                content: header,
                completion: .contentProcessed { [weak self] error in
                    guard let self else {
                        try? fileHandle.close()
                        return
                    }
                    guard error == nil else {
                        try? fileHandle.close()
                        finish()
                        return
                    }
                    sendNext(
                        fileHandle: fileHandle,
                        remaining: range.length
                    )
                }
            )
        }
    }

    private func sendNext(
        data: Data,
        offset: Int,
        remaining: Int
    ) {
        guard remaining > 0 else {
            finish()
            return
        }
        let count = min(Self.responseChunkByteCount, remaining)
        let end = offset + count
        guard offset >= 0, end <= data.count else {
            finish()
            return
        }
        let chunk = data.subdata(in: offset..<end)
        connection.send(
            content: chunk,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                guard error == nil else {
                    finish()
                    return
                }
                sendNext(
                    data: data,
                    offset: end,
                    remaining: remaining - count
                )
            }
        )
    }

    private func sendNext(
        fileHandle: FileHandle,
        remaining: Int64
    ) {
        guard remaining > 0 else {
            try? fileHandle.close()
            finish()
            return
        }
        let count = min(
            Self.responseChunkByteCount,
            Int(remaining)
        )
        let data: Data
        do {
            guard let next = try fileHandle.read(upToCount: count),
                !next.isEmpty
            else {
                try? fileHandle.close()
                finish()
                return
            }
            data = next
        } catch {
            try? fileHandle.close()
            finish()
            return
        }
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    try? fileHandle.close()
                    return
                }
                guard error == nil else {
                    try? fileHandle.close()
                    finish()
                    return
                }
                sendNext(
                    fileHandle: fileHandle,
                    remaining: remaining - Int64(data.count)
                )
            }
        )
    }

    private func sendError(_ error: HLSLocalPlaybackHTTPError) {
        sendAndFinish(
            HLSLocalPlaybackHTTPResponse.errorHeader(error)
        )
    }

    private func sendAndFinish(_ data: Data) {
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] _ in
                self?.finish()
            }
        )
    }

    private func finish() {
        let shouldFinish = didFinish.withLock { didFinish in
            guard !didFinish else {
                return false
            }
            didFinish = true
            return true
        }
        guard shouldFinish else {
            return
        }
        connection.cancel()
        onFinish()
    }
}
#endif
