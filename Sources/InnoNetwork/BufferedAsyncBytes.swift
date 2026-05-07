//
//  BufferedAsyncBytes.swift
//  Network
//
//  Chunked AsyncSequence wrapper used by RequestExecutor to enforce
//  the response-body buffering policy on streaming reads.
//

import Foundation

struct BufferedAsyncBytes<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = [UInt8]

    private let bytes: Base
    private let chunkSize: Int
    private let maxBytes: Int64?

    init(_ bytes: Base, chunkSize: Int = 64 * 1024, maxBytes: Int64? = nil) {
        self.bytes = bytes
        self.chunkSize = Swift.max(1, chunkSize)
        self.maxBytes = maxBytes
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(
            iterator: bytes.makeAsyncIterator(),
            chunkSize: chunkSize,
            maxBytes: maxBytes
        )
    }

    struct Iterator: AsyncIteratorProtocol {
        private var iterator: Base.AsyncIterator
        private let chunkSize: Int
        private let maxBytes: Int64?
        private var observedBytes: Int64 = 0

        fileprivate init(iterator: Base.AsyncIterator, chunkSize: Int, maxBytes: Int64?) {
            self.iterator = iterator
            self.chunkSize = chunkSize
            self.maxBytes = maxBytes
        }

        mutating func next() async throws -> [UInt8]? {
            var chunk: [UInt8] = []
            chunk.reserveCapacity(chunkSize)
            while chunk.count < chunkSize {
                guard let byte = try await iterator.next() else { break }
                observedBytes += 1
                if let maxBytes, observedBytes > maxBytes {
                    throw NetworkError.responseTooLarge(limit: maxBytes, observed: observedBytes)
                }
                chunk.append(byte)
            }
            return chunk.isEmpty ? nil : chunk
        }
    }
}
