import Foundation

struct AIProfile: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case primary
        case saved
        case guest
    }

    let id: String
    var displayName: String
    let kind: Kind

    static let primaryID = "primary"
    static let guestID = "guest"

    func storageID(for providerID: AIProviderID) -> String {
        "\(providerID.rawValue)::\(id)"
    }
}

typealias ChatGPTProfile = AIProfile

private struct StoredAIProfile: Codable {
    let id: String
    var displayName: String
}

private struct StoredProviderProfileState: Codable {
    var savedProfiles: [StoredAIProfile]
    var primaryDisplayName: String
    var lastPersistentProfileID: String
}

private struct ProviderProfileState {
    var savedProfiles: [AIProfile]
    var primaryDisplayName: String
    var activeProfileID: String
    var lastPersistentProfileID: String

    static func empty() -> ProviderProfileState {
        ProviderProfileState(
            savedProfiles: [],
            primaryDisplayName: "Current User",
            activeProfileID: AIProfile.primaryID,
            lastPersistentProfileID: AIProfile.primaryID
        )
    }
}

@MainActor
final class AIProfileManager: ObservableObject {
    @Published private var states: [AIProviderID: ProviderProfileState] = [:]

    static let hideLoggedInUserNameDefaultsKey = "HideLoggedInUserNameInAISelector"

    private static let providerStatesKey = "MultiAIProviderProfileStatesV1"

    private static let legacySavedProfilesKey = "ChatGPTSavedProfiles"
    private static let legacyLastPersistentProfileKey = "ChatGPTLastPersistentProfileID"
    private static let legacyActiveProfileKey = "ChatGPTActiveProfileID"
    private static let legacyPrimaryDisplayNameKey = "ChatGPTPrimaryProfileDisplayName"

    init() {
        loadProviderStates()
    }

    // ChatGPT compatibility surface for code that has not moved to provider-scoped APIs yet.
    var savedProfiles: [AIProfile] { savedProfiles(for: .chatGPT) }
    var primaryDisplayName: String { primaryDisplayName(for: .chatGPT) }
    var primaryProfile: AIProfile { primaryProfile(for: .chatGPT) }
    var guestProfile: AIProfile { guestProfile(for: .chatGPT) }
    var activeProfile: AIProfile { activeProfile(for: .chatGPT) }
    var activeProfileID: String {
        get { activeProfileID(for: .chatGPT) }
        set {
            guard let profile = profile(withID: newValue, for: .chatGPT) else { return }
            selectProfile(profile, for: .chatGPT)
        }
    }

    func profile(withID id: String) -> AIProfile? {
        profile(withID: id, for: .chatGPT)
    }

    func selectProfile(_ profile: AIProfile) {
        selectProfile(profile, for: .chatGPT)
    }

    @discardableResult
    func addLoginProfile() -> AIProfile {
        addLoginProfile(for: .chatGPT)
    }

    func removeSavedProfile(_ profile: AIProfile) {
        removeSavedProfile(profile, for: .chatGPT)
    }

    func updateDetectedDisplayName(_ value: String, for profileID: String) {
        updateDetectedDisplayName(value, for: profileID, providerID: .chatGPT)
    }

    func savedProfiles(for providerID: AIProviderID) -> [AIProfile] {
        state(for: providerID).savedProfiles
    }

    func primaryDisplayName(for providerID: AIProviderID) -> String {
        if UserDefaults.standard.bool(forKey: Self.hideLoggedInUserNameDefaultsKey) {
            return "Current User"
        }
        return state(for: providerID).primaryDisplayName
    }

    func primaryProfile(for providerID: AIProviderID) -> AIProfile {
        AIProfile(
            id: AIProfile.primaryID,
            displayName: primaryDisplayName(for: providerID),
            kind: .primary
        )
    }

    func guestProfile(for providerID: AIProviderID) -> AIProfile {
        AIProfile(id: AIProfile.guestID, displayName: "Guest", kind: .guest)
    }

    func activeProfileID(for providerID: AIProviderID) -> String {
        state(for: providerID).activeProfileID
    }

    func activeProfile(for providerID: AIProviderID) -> AIProfile {
        profile(withID: activeProfileID(for: providerID), for: providerID)
            ?? primaryProfile(for: providerID)
    }

    func profile(withID id: String, for providerID: AIProviderID) -> AIProfile? {
        if id == AIProfile.primaryID { return primaryProfile(for: providerID) }
        if id == AIProfile.guestID { return guestProfile(for: providerID) }
        return state(for: providerID).savedProfiles.first { $0.id == id }
    }

    func selectProfile(_ profile: AIProfile, for providerID: AIProviderID) {
        mutateState(for: providerID) { state in
            state.activeProfileID = profile.id
            if profile.kind != .guest {
                state.lastPersistentProfileID = profile.id
            }
        }
        saveProviderStates()
    }

    @discardableResult
    func addLoginProfile(for providerID: AIProviderID) -> AIProfile {
        var createdProfile: AIProfile!
        mutateState(for: providerID) { state in
            let number = state.savedProfiles.count + 2
            let profile = AIProfile(
                id: UUID().uuidString,
                displayName: "Login \(number)",
                kind: .saved
            )
            state.savedProfiles.append(profile)
            state.activeProfileID = profile.id
            state.lastPersistentProfileID = profile.id
            createdProfile = profile
        }
        saveProviderStates()
        return createdProfile
    }

    func removeSavedProfile(_ profile: AIProfile, for providerID: AIProviderID) {
        guard profile.kind == .saved,
              state(for: providerID).savedProfiles.contains(where: { $0.id == profile.id }) else {
            return
        }

        mutateState(for: providerID) { state in
            state.savedProfiles.removeAll { $0.id == profile.id }
            if state.activeProfileID == profile.id {
                state.activeProfileID = AIProfile.primaryID
            }
            if state.lastPersistentProfileID == profile.id {
                state.lastPersistentProfileID = AIProfile.primaryID
            }
        }
        saveProviderStates()
    }

    func updateDetectedDisplayName(
        _ value: String,
        for profileID: String,
        providerID: AIProviderID
    ) {
        let name = cleanedDisplayName(value)
        guard !name.isEmpty else { return }

        var changed = false
        mutateState(for: providerID) { state in
            if profileID == AIProfile.primaryID {
                guard state.primaryDisplayName != name else { return }
                state.primaryDisplayName = name
                changed = true
                return
            }

            guard let index = state.savedProfiles.firstIndex(where: { $0.id == profileID }),
                  state.savedProfiles[index].displayName != name else {
                return
            }

            state.savedProfiles[index].displayName = name
            changed = true
        }

        if changed {
            saveProviderStates()
        }
    }

    private func state(for providerID: AIProviderID) -> ProviderProfileState {
        states[providerID] ?? .empty()
    }

    private func mutateState(
        for providerID: AIProviderID,
        _ mutation: (inout ProviderProfileState) -> Void
    ) {
        var providerState = state(for: providerID)
        mutation(&providerState)
        states[providerID] = providerState
    }

    private func loadProviderStates() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.providerStatesKey),
           let storedStates = try? JSONDecoder().decode(
               [String: StoredProviderProfileState].self,
               from: data
           ) {
            var loadedStates: [AIProviderID: ProviderProfileState] = [:]

            for providerID in AIProviderID.allCases {
                let stored = storedStates[providerID.rawValue]
                let savedProfiles = stored?.savedProfiles.map {
                    AIProfile(id: $0.id, displayName: $0.displayName, kind: .saved)
                } ?? []
                let requestedProfileID = stored?.lastPersistentProfileID ?? AIProfile.primaryID
                let validProfileID = requestedProfileID == AIProfile.primaryID
                    || savedProfiles.contains(where: { $0.id == requestedProfileID })
                    ? requestedProfileID
                    : AIProfile.primaryID

                loadedStates[providerID] = ProviderProfileState(
                    savedProfiles: savedProfiles,
                    primaryDisplayName: stored?.primaryDisplayName ?? "Current User",
                    activeProfileID: validProfileID,
                    lastPersistentProfileID: validProfileID
                )
            }

            states = loadedStates
            return
        }

        states = Dictionary(
            uniqueKeysWithValues: AIProviderID.allCases.map { ($0, ProviderProfileState.empty()) }
        )
        migrateLegacyChatGPTProfileState()
        saveProviderStates()
    }

    private func migrateLegacyChatGPTProfileState() {
        let defaults = UserDefaults.standard
        let primaryDisplayName = defaults.string(forKey: Self.legacyPrimaryDisplayNameKey)
            ?? "Current User"

        let savedProfiles: [AIProfile]
        if let data = defaults.data(forKey: Self.legacySavedProfilesKey),
           let stored = try? JSONDecoder().decode([StoredAIProfile].self, from: data) {
            savedProfiles = stored.map {
                AIProfile(id: $0.id, displayName: $0.displayName, kind: .saved)
            }
        } else {
            savedProfiles = []
        }

        let restoredProfileID = defaults.string(forKey: Self.legacyLastPersistentProfileKey)
            ?? defaults.string(forKey: Self.legacyActiveProfileKey)
            ?? AIProfile.primaryID
        let validProfileID = restoredProfileID == AIProfile.primaryID
            || savedProfiles.contains(where: { $0.id == restoredProfileID })
            ? restoredProfileID
            : AIProfile.primaryID

        states[.chatGPT] = ProviderProfileState(
            savedProfiles: savedProfiles,
            primaryDisplayName: primaryDisplayName,
            activeProfileID: validProfileID,
            lastPersistentProfileID: validProfileID
        )
    }

    private func saveProviderStates() {
        let storedStates = Dictionary(uniqueKeysWithValues: states.map { providerID, state in
            (
                providerID.rawValue,
                StoredProviderProfileState(
                    savedProfiles: state.savedProfiles.map {
                        StoredAIProfile(id: $0.id, displayName: $0.displayName)
                    },
                    primaryDisplayName: state.primaryDisplayName,
                    lastPersistentProfileID: state.lastPersistentProfileID
                )
            )
        })

        guard let data = try? JSONEncoder().encode(storedStates) else { return }
        UserDefaults.standard.set(data, forKey: Self.providerStatesKey)
        syncLegacyChatGPTState()
    }

    private func syncLegacyChatGPTState() {
        let chatGPTState = state(for: .chatGPT)
        let defaults = UserDefaults.standard
        let storedProfiles = chatGPTState.savedProfiles.map {
            StoredAIProfile(id: $0.id, displayName: $0.displayName)
        }

        if let data = try? JSONEncoder().encode(storedProfiles) {
            defaults.set(data, forKey: Self.legacySavedProfilesKey)
        }
        defaults.set(chatGPTState.lastPersistentProfileID, forKey: Self.legacyLastPersistentProfileKey)
        defaults.set(chatGPTState.lastPersistentProfileID, forKey: Self.legacyActiveProfileKey)
        defaults.set(chatGPTState.primaryDisplayName, forKey: Self.legacyPrimaryDisplayNameKey)
    }

    private func cleanedDisplayName(_ value: String) -> String {
        let trimmed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              trimmed.count <= 120,
              !["chatgpt", "claude", "gemini", "grok", "profile", "account", "menu", "user"]
                .contains(trimmed.lowercased()) else {
            return ""
        }

        return trimmed
    }
}

typealias ChatGPTProfileManager = AIProfileManager
