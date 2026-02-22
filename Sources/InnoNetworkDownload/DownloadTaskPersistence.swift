import Foundation


actor DownloadTaskPersistence {
    struct Record: Codable, Sendable {
        let id: String
        let url: URL
        let destinationURL: URL
    }

    private let key: String
    private let userDefaults: UserDefaults
    private var records: [String: Record]

    init(sessionIdentifier: String, userDefaults: UserDefaults = .standard) {
        self.key = "com.innonetwork.download.tasks.\(sessionIdentifier)"
        self.userDefaults = userDefaults

        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        {
            self.records = decoded
        } else {
            self.records = [:]
        }
    }

    func upsert(id: String, url: URL, destinationURL: URL) {
        records[id] = Record(id: id, url: url, destinationURL: destinationURL)
        persist()
    }

    func remove(id: String) {
        records.removeValue(forKey: id)
        persist()
    }

    func record(forID id: String) -> Record? {
        records[id]
    }

    func record(forURL url: URL?) -> Record? {
        guard let url else { return nil }
        return records.values.first { $0.url == url }
    }

    func prune(keeping ids: Set<String>) {
        let staleKeys = records.keys.filter { !ids.contains($0) }
        guard !staleKeys.isEmpty else { return }
        staleKeys.forEach { records.removeValue(forKey: $0) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: key)
    }
}
