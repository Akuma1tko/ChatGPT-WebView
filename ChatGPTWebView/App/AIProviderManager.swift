import Foundation

@MainActor
final class AIProviderManager: ObservableObject {
    @Published var activeProviderID: AIProviderID {
        didSet {
            UserDefaults.standard.set(activeProviderID.rawValue, forKey: Self.activeProviderKey)
        }
    }

    @Published private(set) var enabledProviderIDs: Set<AIProviderID> {
        didSet {
            let values = enabledProviderIDs.map(\.rawValue).sorted()
            UserDefaults.standard.set(values, forKey: Self.enabledProvidersKey)
        }
    }

    private static let activeProviderKey = "MultiAIActiveProviderID"
    private static let enabledProvidersKey = "MultiAIEnabledProviderIDs"
    private static let deepSeekProviderMigrationKey = "MultiAIDeepSeekProviderMigrationV1"

    init() {
        let defaults = UserDefaults.standard
        let storedEnabled = defaults.stringArray(forKey: Self.enabledProvidersKey) ?? []
        let decodedEnabled = Set(storedEnabled.compactMap(AIProviderID.init(rawValue:)))
        var enabledIDs = decodedEnabled.isEmpty ? Set(AIProviderID.allCases) : decodedEnabled

        if !defaults.bool(forKey: Self.deepSeekProviderMigrationKey) {
            let legacyAllProviders: Set<AIProviderID> = [.chatGPT, .claude, .gemini, .grok]
            if decodedEnabled.isEmpty || decodedEnabled == legacyAllProviders {
                enabledIDs.insert(.deepSeek)
            }
            defaults.set(true, forKey: Self.deepSeekProviderMigrationKey)
            defaults.set(enabledIDs.map(\.rawValue).sorted(), forKey: Self.enabledProvidersKey)
        }

        self.enabledProviderIDs = enabledIDs

        if let rawValue = defaults.string(forKey: Self.activeProviderKey),
           let providerID = AIProviderID(rawValue: rawValue),
           enabledIDs.contains(providerID) {
            self.activeProviderID = providerID
        } else {
            self.activeProviderID = AIProvider.all.first(where: { enabledIDs.contains($0.id) })?.id ?? .chatGPT
        }
    }

    var activeProvider: AIProvider {
        activeProviderID.provider
    }

    var allProviders: [AIProvider] {
        AIProvider.all
    }

    var providers: [AIProvider] {
        AIProvider.all.filter { enabledProviderIDs.contains($0.id) }
    }

    func isProviderEnabled(_ providerID: AIProviderID) -> Bool {
        enabledProviderIDs.contains(providerID)
    }

    func setProviderEnabled(_ providerID: AIProviderID, enabled: Bool) {
        if enabled {
            enabledProviderIDs.insert(providerID)
            return
        }

        guard enabledProviderIDs.count > 1 else {
            return
        }

        enabledProviderIDs.remove(providerID)
        if activeProviderID == providerID,
           let replacement = providers.first {
            activeProviderID = replacement.id
        }
    }

    func selectProvider(_ provider: AIProvider) {
        guard enabledProviderIDs.contains(provider.id) else { return }
        activeProviderID = provider.id
    }
}
