import Foundation

@MainActor
final class SupabaseConfigStore: ObservableObject {
    @Published private(set) var config: SupabaseAppConfig?

    private let defaultsKey = "supabase_app_config_v1"

    init() {
        self.config = Self.loadConfig(defaultsKey: defaultsKey)
    }

    func save(projectURLText: String, publishableKey: String) throws {
        let normalized = try SupabaseConfigValidation.normalize(
            projectURLText: projectURLText,
            publishableKey: publishableKey
        )

        let data = try JSONEncoder().encode(normalized)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        self.config = normalized
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        self.config = nil
    }

    private static func loadConfig(defaultsKey: String) -> SupabaseAppConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SupabaseAppConfig.self, from: data)
    }
}
