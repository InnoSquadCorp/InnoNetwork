import Foundation
import InnoNetworkHLS

struct HLSLiveDVRResourceWriter: Sendable {
    private let client: HLSHTTPClient
    private let resourceLoader: HLSLiveDVRResourceLoader
    private let configuration: HLSLiveDVRConfiguration

    init(
        client: HLSHTTPClient,
        configuration: HLSLiveDVRConfiguration
    ) {
        self.client = client
        self.resourceLoader = HLSLiveDVRResourceLoader(
            client: client,
            requestTimeout: configuration.limits.requestTimeout
        )
        self.configuration = configuration
    }

    func makeContext(
        workspace: HLSLiveDVRWorkspace
    ) -> HLSLiveDVRResourceContext {
        HLSLiveDVRResourceContext(
            keyCache: HLSAES128KeyCache(client: client),
            diskCapacityGuard: HLSDiskCapacityGuard(
                directoryURL: workspace.directoryURL,
                policy: configuration.limits.diskCapacityPolicy
            )
        )
    }

    func retainInitializationIfNeeded(
        state: inout HLSLiveDVRRecordingState,
        context: HLSLiveDVRResourceContext
    ) async throws -> Bool {
        guard
            state.container == .fragmentedMP4,
            state.initializationFileName == nil
        else {
            return true
        }
        guard let initialization = state.initializationSegment else {
            throw HLSLiveDVRError.unsupportedFeature(
                .missingInitializationSegment
            )
        }
        let path =
            "resources/initialization."
            + HLSLiveDVRPlaylistWriter.fileExtension(
                for: initialization.url,
                fallback: "mp4"
            )
        let destinationURL = state.workspace.directoryURL
            .appendingPathComponent(path)
        let result = try await load(
            sourceURL: initialization.url,
            byteRange: initialization.byteRange,
            encryption: initialization.encryption,
            resourceIndex: state.nextResourceIndex,
            destinationURL: destinationURL,
            state: state,
            context: context
        )
        switch result {
        case .retained(let byteCount):
            try state.retainInitialization(
                fileName: path,
                byteCount: byteCount
            )
            return true
        case .totalLimitReached:
            return false
        }
    }

    func retain(
        _ segment: HLSLiveSegment,
        state: inout HLSLiveDVRRecordingState,
        context: HLSLiveDVRResourceContext
    ) async throws -> Bool {
        let fallbackExtension: String
        switch state.container {
        case .mpegTransportStream:
            fallbackExtension = "ts"
        case .fragmentedMP4:
            fallbackExtension = "m4s"
        case nil:
            throw HLSLiveDVRError.unsupportedFeature(
                .unknownMediaContainer
            )
        }
        let path = String(
            format: "resources/%05d.%@",
            state.segments.count,
            HLSLiveDVRPlaylistWriter.fileExtension(
                for: segment.url,
                fallback: fallbackExtension
            )
        )
        let destinationURL = state.workspace.directoryURL
            .appendingPathComponent(path)
        let result = try await load(
            sourceURL: segment.url,
            byteRange: segment.byteRange,
            encryption: segment.encryption,
            resourceIndex: state.nextResourceIndex,
            destinationURL: destinationURL,
            state: state,
            context: context
        )
        switch result {
        case .retained(let byteCount):
            try state.retain(
                segment,
                fileName: path,
                byteCount: byteCount
            )
            return true
        case .totalLimitReached:
            return false
        }
    }

    func retainRenditionInitializationIfNeeded(
        at index: Int,
        state: inout HLSLiveDVRRecordingState,
        context: HLSLiveDVRResourceContext
    ) async throws -> Bool {
        guard
            try state.renditionContainer(at: index) == .fragmentedMP4,
            state.renditionInitializationFileName(at: index) == nil
        else {
            return true
        }
        guard
            let initialization = state.renditionInitializationSegment(
                at: index
            )
        else {
            throw HLSLiveDVRError.unsupportedFeature(
                .missingInitializationSegment
            )
        }
        let fileName =
            "resources/initialization."
            + HLSLiveDVRPlaylistWriter.fileExtension(
                for: initialization.url,
                fallback: "mp4"
            )
        let directoryPath = try state.renditionDirectoryPath(at: index)
        let destinationURL = try renditionResourceURL(
            directoryPath: directoryPath,
            relativeFileName: fileName,
            workspace: state.workspace
        )
        let result = try await load(
            sourceURL: initialization.url,
            byteRange: initialization.byteRange,
            encryption: initialization.encryption,
            resourceIndex: state.nextResourceIndex,
            destinationURL: destinationURL,
            state: state,
            context: context
        )
        switch result {
        case .retained(let byteCount):
            try state.retainRenditionInitialization(
                at: index,
                fileName: fileName,
                byteCount: byteCount
            )
            return true
        case .totalLimitReached:
            return false
        }
    }

    func retainRendition(
        _ segment: HLSLiveSegment,
        at index: Int,
        state: inout HLSLiveDVRRecordingState,
        context: HLSLiveDVRResourceContext
    ) async throws -> Bool {
        let fallbackExtension: String
        switch try state.renditionContainer(at: index) {
        case .mpegTransportStream:
            fallbackExtension = "ts"
        case .fragmentedMP4:
            fallbackExtension = "m4s"
        }
        let fileName = String(
            format: "resources/%05d.%@",
            state.renditionSegmentCount(at: index),
            HLSLiveDVRPlaylistWriter.fileExtension(
                for: segment.url,
                fallback: fallbackExtension
            )
        )
        let directoryPath = try state.renditionDirectoryPath(at: index)
        let destinationURL = try renditionResourceURL(
            directoryPath: directoryPath,
            relativeFileName: fileName,
            workspace: state.workspace
        )
        let result = try await load(
            sourceURL: segment.url,
            byteRange: segment.byteRange,
            encryption: segment.encryption,
            resourceIndex: state.nextResourceIndex,
            destinationURL: destinationURL,
            state: state,
            context: context
        )
        switch result {
        case .retained(let byteCount):
            try state.retainRendition(
                segment,
                at: index,
                fileName: fileName,
                byteCount: byteCount
            )
            return true
        case .totalLimitReached:
            return false
        }
    }

    private func renditionResourceURL(
        directoryPath: String,
        relativeFileName: String,
        workspace: HLSLiveDVRWorkspace
    ) throws -> URL {
        let directoryURL = workspace.directoryURL
            .appendingPathComponent(directoryPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL.appendingPathComponent(
                    "resources",
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        return directoryURL.appendingPathComponent(relativeFileName)
    }

    private func load(
        sourceURL: URL,
        byteRange: HLSByteRange?,
        encryption: HLSLiveAES128Encryption?,
        resourceIndex: Int,
        destinationURL: URL,
        state: HLSLiveDVRRecordingState,
        context: HLSLiveDVRResourceContext
    ) async throws -> HLSLiveDVRLoadResult {
        let remainingBytes =
            configuration.limits.maximumTotalMediaBytes
            - state.mediaByteCount
        guard remainingBytes > 0 else {
            return .totalLimitReached
        }
        let maximumRetainedBytes64 = min(
            Int64(configuration.limits.maximumMediaResourceBytes),
            remainingBytes,
            Int64(Int.max)
        )
        guard maximumRetainedBytes64 > 0 else {
            return .totalLimitReached
        }
        let paddingAllowance: Int64 = encryption == nil ? 0 : 16
        let (totalBoundedTransferBytes, transferOverflow) =
            maximumRetainedBytes64.addingReportingOverflow(
                paddingAllowance
            )
        let maximumBytes64 = min(
            Int64(configuration.limits.maximumMediaResourceBytes),
            transferOverflow ? .max : totalBoundedTransferBytes,
            Int64(Int.max)
        )
        do {
            return .retained(
                try await resourceLoader.load(
                    from: sourceURL,
                    byteRange: byteRange,
                    encryption: encryption,
                    resourceIndex: resourceIndex,
                    maximumBytes: Int(maximumBytes64),
                    maximumRetainedBytes: Int(maximumRetainedBytes64),
                    keyCache: context.keyCache,
                    diskCapacityGuard: context.diskCapacityGuard,
                    destinationURL: destinationURL
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSLiveDVRResourceLoadError {
            switch error {
            case .bodyLimitExceeded:
                if maximumBytes64
                    < Int64(
                        configuration.limits.maximumMediaResourceBytes
                    )
                {
                    return .totalLimitReached
                }
                throw HLSLiveDVRError.mediaResourceTooLarge
            case .retainedLimitExceeded:
                return .totalLimitReached
            case .invalidByteRangeResponse:
                throw HLSLiveDVRError.invalidByteRangeResponse
            case .invalidResponseStatus(let statusCode):
                throw HLSLiveDVRError.invalidMediaResponseStatus(
                    statusCode
                )
            case .emptyResponse, .transferFailed:
                throw HLSLiveDVRError.transferFailed
            }
        } catch let error as HLSLiveDVRError {
            throw error
        } catch let error as HLSDownloadError {
            switch error {
            case .invalidAES128Key:
                throw HLSLiveDVRError.invalidEncryptionKey
            case .invalidAES128KeyResponseStatus(let statusCode):
                throw HLSLiveDVRError.invalidEncryptionKeyResponseStatus(
                    statusCode
                )
            case .aes128DecryptionFailed:
                throw HLSLiveDVRError.decryptionFailed
            case .diskCapacityUnavailable:
                throw HLSLiveDVRError.diskCapacityUnavailable
            case .insufficientDiskCapacity(let required, let available):
                throw HLSLiveDVRError.insufficientDiskCapacity(
                    required: required,
                    available: available
                )
            default:
                throw HLSLiveDVRError.transferFailed
            }
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
    }
}

struct HLSLiveDVRResourceContext: Sendable {
    let keyCache: HLSAES128KeyCache
    let diskCapacityGuard: HLSDiskCapacityGuard
}

private enum HLSLiveDVRLoadResult {
    case retained(Int64)
    case totalLimitReached
}
