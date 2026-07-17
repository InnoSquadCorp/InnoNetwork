import Foundation

enum DownloadDestinationResolver {
    static func resolve(
        sourceURL: URL,
        directory: URL,
        fileName: String?
    ) -> URL {
        let rawName = fileName ?? sourceURL.lastPathComponent
        let name = safeFileName(rawName) ?? "download-\(UUID().uuidString)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func safeFileName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafePathComponent(name) else { return nil }
        guard isSafePathComponent(name.precomposedStringWithCompatibilityMapping) else { return nil }
        return name
    }

    private static func isSafePathComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.contains("/") == false,
            name.contains("\\") == false,
            name.contains(":") == false
        else {
            return false
        }
        return !name.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
