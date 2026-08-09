import CommonCrypto
import Foundation
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("AES-128 media is decrypted with an explicit IV")
    func downloadsAES128Media() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/encrypted.m3u8")
        )
        let keyURL = try #require(
            URL(string: "https://media.example/key.bin?token=secret")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let key = Data(0..<16)
        let initializationVector = Data(16..<32)
        let plaintext = Data("decrypted media payload".utf8)
        let ciphertext = try aes128Encrypt(
            plaintext,
            key: key,
            initializationVector: initializationVector
        )
        let session = makeAES128Session()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-KEY:METHOD=AES-128,URI="key.bin?token=secret",IV=0x101112131415161718191a1b1c1d1e1f
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: key,
                headers: ["Content-Length": "\(key.count)"]
            ),
            for: keyURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: ciphertext,
                headers: [
                    "Content-Length": "\(ciphertext.count)"
                ]
            ),
            for: segmentURL
        )
        let directoryURL = try makeAES128TemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "decrypted.ts"
        )
        let requestRecorder = HLSRequestEventRecorder()

        var progressEvents: [HLSDownloadProgress] = []
        var didComplete = false
        for await event in HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                transfer: HLSTransferPack(retryPolicy: nil)
            ),
            requestPolicy: HLSRequestPolicy(
                eventObservers: [requestRecorder]
            )
        ).download(
            sourceURL: playlistURL,
            destinationURL: destinationURL
        ) {
            switch event {
            case .progress(let progress):
                progressEvents.append(progress)
            case .completed:
                didComplete = true
            case .failed(let error):
                Issue.record("Unexpected AES-128 failure: \(error)")
            case .cancelled:
                Issue.record("Unexpected AES-128 cancellation.")
            }
        }

        #expect(didComplete)
        #expect(try Data(contentsOf: destinationURL) == plaintext)
        let finalProgress = try #require(progressEvents.last)
        #expect(
            finalProgress.totalBytesWritten
                == Int64(plaintext.count)
        )
        #expect(
            finalProgress.totalBytesExpectedToWrite
                == Int64(plaintext.count)
        )
        let requestContexts = await requestRecorder.startedContexts()
        #expect(
            requestContexts.map(\.purpose)
                == [
                    .entryPlaylist,
                    .encryptionKey,
                    .mediaResource,
                ]
        )
        #expect(
            requestContexts.last?.resourceIndex == 0
        )
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [playlistURL, keyURL, segmentURL]
        )
        let keyRequest = try #require(
            HLSURLProtocol.capturedRequests().first {
                $0.url == keyURL
            }
        )
        #expect(
            keyRequest.value(forHTTPHeaderField: "Cache-Control")
                == "no-store"
        )
        #expect(
            keyRequest.cachePolicy
                == .reloadIgnoringLocalCacheData
        )
        let persistedText = try directoryTextContents(directoryURL)
        #expect(!persistedText.contains("token=secret"))
        #expect(!persistedText.contains(key.base64EncodedString()))
    }

    @Test("prepare does not fetch AES-128 keys or media")
    func preparesAES128MetadataWithoutFetchingSecrets() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/encrypted.m3u8")
        )
        let keyURL = try #require(
            URL(string: "https://media.example/key.bin")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeAES128Session()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )

        let preparation = try await HLSDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSStoragePack(
                    diskCapacityPolicy: .disabled
                )
            )
        ).prepare(sourceURL: playlistURL)

        #expect(preparation.segmentCount == 1)
        #expect(preparation.resourceTransferCount == 1)
        #expect(
            HLSURLProtocol.capturedRequests().compactMap(\.url)
                == [playlistURL]
        )
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == keyURL || $0.url == segmentURL
            }
        )
    }

    @Test("AES-128 key HTTP status fails before media transfer")
    func rejectsAES128KeyHTTPStatus() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/encrypted.m3u8")
        )
        let keyURL = try #require(
            URL(string: "https://media.example/key.bin")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeAES128Session()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 403,
                data: Data(),
                headers: [:]
            ),
            for: keyURL
        )
        let directoryURL = try makeAES128TemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let event = await aes128TerminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled
                    ),
                    transfer: HLSTransferPack(retryPolicy: nil)
                )
            ).download(
                sourceURL: playlistURL,
                destinationURL:
                    directoryURL.appendingPathComponent(
                        "rejected.ts"
                    )
            )
        )

        #expect(
            {
                if case .failed(
                    .invalidAES128KeyResponseStatus(403)
                ) = event {
                    return true
                }
                return false
            }()
        )
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == segmentURL
            }
        )
    }

    @Test("invalid AES-128 key length fails before media transfer")
    func rejectsInvalidAES128KeyLength() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/encrypted.m3u8")
        )
        let keyURL = try #require(
            URL(string: "https://media.example/key.bin")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeAES128Session()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(repeating: 0, count: 15),
                headers: ["Content-Length": "15"]
            ),
            for: keyURL
        )
        let directoryURL = try makeAES128TemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "rejected.ts"
        )

        let event = await aes128TerminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled
                    ),
                    transfer: HLSTransferPack(retryPolicy: nil)
                )
            ).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        #expect(
            {
                if case .failed(.invalidAES128Key) = event {
                    return true
                }
                return false
            }()
        )
        #expect(
            !HLSURLProtocol.capturedRequests().contains {
                $0.url == segmentURL
            }
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationURL.path
            )
        )
    }

    @Test("invalid AES-128 ciphertext fails without committing output")
    func rejectsInvalidAES128Ciphertext() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/encrypted.m3u8")
        )
        let keyURL = try #require(
            URL(string: "https://media.example/key.bin")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let session = makeAES128Session()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(repeating: 0, count: 16),
                headers: ["Content-Length": "16"]
            ),
            for: keyURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(repeating: 0, count: 15),
                headers: ["Content-Length": "15"]
            ),
            for: segmentURL
        )
        let directoryURL = try makeAES128TemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            "rejected.ts"
        )

        let event = await aes128TerminalEvent(
            from: HLSDownloader(
                session: session,
                configuration: .advanced(
                    storage: HLSStoragePack(
                        diskCapacityPolicy: .disabled
                    ),
                    transfer: HLSTransferPack(retryPolicy: nil)
                )
            ).download(
                sourceURL: playlistURL,
                destinationURL: destinationURL
            )
        )

        guard case .failed(.aes128DecryptionFailed) = event else {
            Issue.record(
                "Expected AES-128 decryption failure, got \(String(reflecting: event))."
            )
            return
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationURL.path
            )
        )
    }

    @Test("offline packages persist plaintext and remove key declarations")
    func localizesDecryptedAES128Package() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/encrypted.m3u8")
        )
        let keyURL = try #require(
            URL(string: "https://media.example/key.bin")
        )
        let segmentURL = try #require(
            URL(string: "https://media.example/segment.ts")
        )
        let key = Data(0..<16)
        let initializationVector = Data(16..<32)
        let plaintext = Data("offline plaintext".utf8)
        let ciphertext = try aes128Encrypt(
            plaintext,
            key: key,
            initializationVector: initializationVector
        )
        let session = makeAES128Session()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x101112131415161718191a1b1c1d1e1f
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: key,
                headers: ["Content-Length": "16"]
            ),
            for: keyURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: ciphertext,
                headers: [
                    "Content-Length": "\(ciphertext.count)"
                ]
            ),
            for: segmentURL
        )
        let parentURL = try makeAES128TemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parentURL)
        }
        let packageURL = parentURL.appendingPathComponent(
            "encrypted.hlspkg",
            isDirectory: true
        )

        let receipt = try await HLSOfflinePackageDownloader(
            session: session,
            configuration: .advanced(
                storage: HLSOfflinePackageStoragePack(
                    diskCapacityPolicy: .disabled
                ),
                transfer: HLSTransferPack(retryPolicy: nil)
            )
        ).downloadPackage(
            sourceURL: playlistURL,
            destinationDirectoryURL: packageURL
        )
        let primaryTrack = try #require(receipt.tracks.first)
        let primaryPlaylistURL =
            packageURL.appendingPathComponent(
                primaryTrack.relativePlaylistPath
            )
        let localizedPlaylist = try String(
            contentsOf: primaryPlaylistURL,
            encoding: .utf8
        )
        let localizedResourceURL =
            primaryPlaylistURL.deletingLastPathComponent()
            .appendingPathComponent("resources/00000.ts")

        #expect(!localizedPlaylist.contains("#EXT-X-KEY"))
        #expect(
            try Data(contentsOf: localizedResourceURL)
                == plaintext
        )
    }

    @Test("media sequence numbers derive distinct AES-128 IVs")
    func derivesImplicitAES128InitializationVectors() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/encrypted.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:257
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXTINF:1,
            first.ts
            #EXTINF:1,
            second.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )
        let resources = try #require(playlist.media?.resources)

        #expect(
            resources.map(\.encryption?.initializationVector)
                == [
                    Data(
                        [
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 1, 1,
                        ]
                    ),
                    Data(
                        [
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 1, 2,
                        ]
                    ),
                ]
        )
    }

    private func directoryTextContents(
        _ directoryURL: URL
    ) throws -> String {
        let fileManager = FileManager.default
        let enumerator = try #require(
            fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        var contents = ""
        for case let url as URL in enumerator {
            guard
                try url.resourceValues(
                    forKeys: [.isRegularFileKey]
                ).isRegularFile == true,
                let text = String(
                    data: try Data(contentsOf: url),
                    encoding: .utf8
                )
            else {
                continue
            }
            contents += text
        }
        return contents
    }

    private func makeAES128Session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeAES128TemporaryDirectory() throws -> URL {
        let directoryURL =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HLSAES128Tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func aes128TerminalEvent(
        from stream: AsyncStream<HLSDownloadEvent>
    ) async -> HLSDownloadEvent? {
        for await event in stream {
            switch event {
            case .completed, .failed, .cancelled:
                return event
            case .progress:
                continue
            }
        }
        return nil
    }
}

private func aes128Encrypt(
    _ plaintext: Data,
    key: Data,
    initializationVector: Data
) throws -> Data {
    var ciphertext = Data(
        count: plaintext.count + kCCBlockSizeAES128
    )
    let outputCapacity = ciphertext.count
    var outputLength = 0
    let status = ciphertext.withUnsafeMutableBytes { outputBytes in
        plaintext.withUnsafeBytes { plaintextBytes in
            key.withUnsafeBytes { keyBytes in
                initializationVector.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        plaintextBytes.baseAddress,
                        plaintext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else {
        throw HLSDownloadError.aes128DecryptionFailed
    }
    ciphertext.count = outputLength
    return ciphertext
}
