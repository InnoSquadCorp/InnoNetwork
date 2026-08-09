import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkHLS

@Suite("HLS public models")
struct HLSModelsTests {
    @Test("unknown progress is represented without a Foundation sentinel")
    func indeterminateProgressIsExplicit() {
        let progress = HLSDownloadProgress.zero

        #expect(progress.totalBytesExpectedToWrite == nil)
        #expect(progress.isIndeterminate)
        #expect(progress.fractionCompleted == nil)
        #expect(progress.percentCompleted == nil)
    }

    @Test("a known empty transfer reports zero progress")
    func emptyProgressIsDeterminate() {
        let progress = HLSDownloadProgress(
            bytesWritten: 0,
            totalBytesWritten: 0,
            totalBytesExpectedToWrite: 0
        )

        #expect(!progress.isIndeterminate)
        #expect(progress.fractionCompleted == 0)
        #expect(progress.percentCompleted == 0)
    }

    @Test("transfer failures preserve stable and underlying error codes")
    func transferFailurePreservesCodes() {
        let underlying = SendableUnderlyingError(
            domain: NSURLErrorDomain,
            code: URLError.timedOut.rawValue,
            message: "The request timed out."
        )
        let error = HLSDownloadError.transferFailed(underlying)

        #expect(error.code == .transferFailed)
        #expect(error.errorCode == HLSDownloadErrorCode.transferFailed.rawValue)
        #expect(HLSDownloadError.errorDomain == "com.innosquad.innonetwork.hls")
        #expect(
            error.errorUserInfo[NSUnderlyingErrorKey]
                as? SendableUnderlyingError == underlying
        )
    }

    @Test("HTTP failures expose status through NSError user info")
    func statusFailureExposesStatusCode() {
        let error = HLSDownloadError.invalidMediaResponseStatus(503)

        #expect(error.code == .invalidMediaResponseStatus)
        #expect(
            error.errorUserInfo[HLSDownloadError.statusCodeUserInfoKey]
                as? Int == 503
        )
    }

    @Test("unsupported media features preserve stable classification")
    func unsupportedMediaFeaturePreservesClassification() {
        let error = HLSDownloadError.unsupportedMediaFeature(.gap)

        #expect(error.code == .unsupportedMediaFeature)
        #expect(
            error.errorCode
                == HLSDownloadErrorCode.unsupportedMediaFeature.rawValue
        )
        #expect(error.localizedDescription.contains("EXT-X-GAP"))
    }

    @Test("invalid byte-range responses preserve stable classification")
    func invalidByteRangeResponsePreservesClassification() {
        let error = HLSDownloadError.invalidByteRangeResponse

        #expect(error.code == .invalidByteRangeResponse)
        #expect(
            error.errorCode
                == HLSDownloadErrorCode.invalidByteRangeResponse.rawValue
        )
    }

    @Test("AES-128 failures preserve stable classifications")
    func aes128FailuresPreserveClassifications() {
        #expect(
            HLSDownloadError.invalidAES128Key.code
                == .invalidAES128Key
        )
        #expect(
            HLSDownloadError.aes128DecryptionFailed.code
                == .aes128DecryptionFailed
        )
        #expect(
            HLSDownloadErrorCode.invalidAES128Key.rawValue == 7_024
        )
        #expect(
            HLSDownloadErrorCode.aes128DecryptionFailed.rawValue
                == 7_025
        )
        let keyStatus =
            HLSDownloadError.invalidAES128KeyResponseStatus(403)
        #expect(keyStatus.code == .invalidAES128KeyResponseStatus)
        #expect(
            keyStatus.errorUserInfo[
                HLSDownloadError.statusCodeUserInfoKey
            ] as? Int == 403
        )
        #expect(
            HLSDownloadErrorCode.invalidAES128KeyResponseStatus
                .rawValue == 7_026
        )
    }

    @Test("legacy byte-range error does not claim the feature is unsupported")
    func legacyByteRangeErrorIsAccurate() {
        let description =
            HLSDownloadError.byteRangePlaylistUnsupported
            .localizedDescription

        #expect(description.contains("legacy"))
        #expect(description.contains("byte ranges are supported"))
    }

    @Test("error diagnostics align retry and user-visible decisions")
    func errorDiagnostics() {
        let transientStatus =
            HLSDownloadError.invalidMediaResponseStatus(503)
        #expect(transientStatus.isRetriableHint)
        #expect(transientStatus.isUserVisible)
        #expect(transientStatus.recoverySuggestion?.isEmpty == false)
        #expect(
            transientStatus.errorUserInfo[
                NSLocalizedRecoverySuggestionErrorKey
            ] as? String == transientStatus.recoverySuggestion
        )

        #expect(
            !HLSDownloadError.invalidResponseStatus(404)
                .isRetriableHint
        )
        #expect(HLSDownloadError.destinationInUse.isRetriableHint)
        #expect(!HLSDownloadError.invalidDestination.isUserVisible)

        let cancelledTransfer = HLSDownloadError.transferFailed(
            SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled,
                message: "cancelled"
            )
        )
        #expect(!cancelledTransfer.isRetriableHint)

        let timeoutTransfer = HLSDownloadError.transferFailed(
            SendableUnderlyingError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                message: "timed out",
                recoverySuggestion: "Try again."
            )
        )
        #expect(timeoutTransfer.isRetriableHint)
        #expect(timeoutTransfer.recoverySuggestion == "Try again.")
    }
}
