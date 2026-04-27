import Foundation
import Testing
@testable import InnoNetwork


@Suite("Multipart MIME Type Tests")
struct MultipartMIMETypeTests {

    /// Pre-existing extension → MIME mappings from before the UTType refactor.
    /// Each test below asserts that UTType produces a value that is at least
    /// as specific. Any regression here means the standard library no longer
    /// resolves an extension we previously supported.
    @Test(
        "UTType-backed mimeType(for:) covers the legacy hand-rolled table",
        arguments: [
            ("jpg", "image/jpeg"),
            ("jpeg", "image/jpeg"),
            ("png", "image/png"),
            ("gif", "image/gif"),
            ("heic", "image/heic"),
            ("pdf", "application/pdf"),
            ("json", "application/json"),
            ("txt", "text/plain"),
            ("html", "text/html"),
            ("mp4", "video/mp4"),
            ("mov", "video/quicktime"),
            ("mp3", "audio/mpeg"),
            ("zip", "application/zip"),
        ] as [(String, String)]
    )
    func legacyExtensionMappings(ext: String, expected: String) {
        let actual = MultipartFormData.mimeType(for: ext)
        let topLevelType = expected.split(separator: "/", maxSplits: 1).first.map(String.init) ?? expected
        #expect(
            actual == expected || actual.hasPrefix("\(topLevelType)/"),
            "extension '\(ext)' expected \(expected) or \(topLevelType)/*, got \(actual)"
        )
    }

    /// `wav` deliberately omitted from the parametric test above because
    /// UTType resolves it to `audio/wav` on some platforms and `audio/x-wav`
    /// or `audio/wave` on others. Either is a valid IANA-registered type, so
    /// the test only requires the top-level audio/ category.
    @Test("WAV resolves to an audio/* MIME type")
    func wavResolvesToAudioCategory() {
        let actual = MultipartFormData.mimeType(for: "wav")
        #expect(actual.hasPrefix("audio/"), "wav resolved to non-audio MIME: \(actual)")
    }

    @Test("Unknown extensions fall back to application/octet-stream")
    func unknownExtensionFallsBack() {
        #expect(MultipartFormData.mimeType(for: "thisIsNotARealExtension") == "application/octet-stream")
        #expect(MultipartFormData.mimeType(for: "") == "application/octet-stream")
    }

    @Test(
        "Modern extensions (webp, avif, heif, m4a, webm) now resolve through UTType",
        arguments: ["webp", "avif", "heif", "m4a", "webm"]
    )
    func modernExtensionsAreSupported(ext: String) {
        let actual = MultipartFormData.mimeType(for: ext)
        // Only assert that we did NOT fall back to octet-stream — the
        // specific MIME (e.g. image/webp vs image/x-webp) is a UTType
        // implementation detail we accept.
        #expect(actual != "application/octet-stream", "extension '\(ext)' fell back unexpectedly: \(actual)")
    }

    @Test("Default boundary carries the library marker for debuggability")
    func defaultBoundaryIsPrefixed() {
        let formData = MultipartFormData()
        #expect(formData.boundary.hasPrefix("InnoNetwork.boundary."))
        // Suffix is a UUID, so the length after the marker is fixed.
        #expect(formData.boundary.count == "InnoNetwork.boundary.".count + 36)
    }
}
