import Foundation

final class ChatGPTSessionURLCheckpoint {
    private struct Record: Codable {
        let url: String
        let savedAt: Date
    }

    private let defaults: UserDefaults
    private let keyPrefix = "ContextPort.sessionURLCheckpoint.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ url: URL, profileID: String) {
        guard url.scheme?.lowercased() == "https" else { return }

        let record = Record(url: url.absoluteString, savedAt: Date())
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key(for: profileID))
    }

    func url(profileID: String) -> URL? {
        guard let data = defaults.data(forKey: key(for: profileID)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let url = URL(string: record.url),
              url.scheme?.lowercased() == "https" else {
            return nil
        }

        return url
    }

    func delete(profileID: String) {
        defaults.removeObject(forKey: key(for: profileID))
    }

    func deleteAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(for profileID: String) -> String {
        let encoded = Data(profileID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return keyPrefix + encoded
    }
}
