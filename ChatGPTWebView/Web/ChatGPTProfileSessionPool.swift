import Foundation
import UIKit
import WebKit

private struct AIProfileSessionKey: Hashable {
    let providerID: AIProviderID
    let profileID: String
}

@MainActor
final class ChatGPTProfileSessionPool: NSObject, ObservableObject {
    static let restoreLastChatDefaultsKey = "restoreLastChatEnabled"

    private var stores: [AIProfileSessionKey: ChatGPTWebViewStore] = [:]
    private var chatPerformanceConfiguration: ChatPerformanceConfiguration = .disabled
    private let sessionURLCheckpoint = ChatGPTSessionURLCheckpoint()
    private var restoreLastChatEnabled: Bool

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.restoreLastChatDefaultsKey) == nil {
            restoreLastChatEnabled = true
        } else {
            restoreLastChatEnabled = defaults.bool(forKey: Self.restoreLastChatDefaultsKey)
        }

        super.init()

        if !restoreLastChatEnabled {
            clearSavedSessionURLs()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkpointSessionsBeforeSuspension),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkpointSessionsBeforeSuspension),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func checkpointSessionsBeforeSuspension() {
        checkpointAllSessionURLs()
    }

    // ChatGPT compatibility surface for existing callers.
    func store(
        for profile: ChatGPTProfile,
        onDetectedDisplayName: @escaping (String, String) -> Void
    ) -> ChatGPTWebViewStore {
        store(
            for: AIProviderID.chatGPT.provider,
            profile: profile,
            onDetectedDisplayName: onDetectedDisplayName
        )
    }

    func persistSession(profileID: String) async {
        await persistSession(providerID: .chatGPT, profileID: profileID)
    }

    func setTypingPriority(_ isTyping: Bool, profileID: String) {
        setTypingPriority(isTyping, providerID: .chatGPT, profileID: profileID)
    }

    func removeSavedProfileSession(profileID: String) async {
        await removeSavedProfileSession(providerID: .chatGPT, profileID: profileID)
    }

    func resetGuest(
        profile: ChatGPTProfile,
        onDetectedDisplayName: @escaping (String, String) -> Void
    ) async {
        await resetGuest(
            provider: AIProviderID.chatGPT.provider,
            profile: profile,
            onDetectedDisplayName: onDetectedDisplayName
        )
    }

    func store(
        for provider: AIProvider,
        profile: ChatGPTProfile,
        onDetectedDisplayName: @escaping (String, String) -> Void
    ) -> ChatGPTWebViewStore {
        let key = AIProfileSessionKey(providerID: provider.id, profileID: profile.id)
        if let existing = stores[key] {
            existing.updateChatPerformanceConfiguration(chatPerformanceConfiguration)
            existing.updateLatestExchangeConfiguration(chatPerformanceConfiguration)
            existing.updateChatGPTMobileWebFallback(
                chatPerformanceConfiguration.chatGPTMobileWebFallbackEnabled
            )
            return existing
        }

        let navigationLabels = ["help", "help center", "support", "claude help center"]
        let existingProfileName = profile.displayName
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if navigationLabels.contains(existingProfileName) {
            onDetectedDisplayName(profile.id, "Current User")
        }

        let cookieVault = ChatGPTProfileCookieVault()
        let browserStateVault = ChatGPTProfileBrowserStateVault()
        let storageProfileID = profile.storageID(for: provider.id)

        // Reject a previously captured provider URL when the full authenticated URL rule
        // no longer accepts it. This clears stale Claude help/support routes without
        // discarding the provider cookie snapshot that may still contain a valid login.
        if restoreLastChatEnabled,
           profile.kind != .guest,
           let restoredURL = browserStateVault.lastURL(
            profileID: storageProfileID,
            allowedHostSuffixes: provider.authenticatedHostSuffixes
           ),
           !provider.isAuthenticatedContentURL(restoredURL) {
            browserStateVault.delete(profileID: storageProfileID)
        }

        // ChatGPT Current User keeps the shared default WebKit store for upgrade/session
        // compatibility. Other providers use the existing persistent-profile recovery
        // layer over an isolated nonpersistent WebKit store so Google/Apple auth state
        // cannot bleed between Claude, Gemini, and Grok Current User sessions.
        let webViewProfile: ChatGPTProfile
        if provider.id != .chatGPT, profile.kind == .primary {
            webViewProfile = ChatGPTProfile(
                id: profile.id,
                displayName: profile.displayName,
                kind: .saved
            )
        } else {
            webViewProfile = profile
        }

        let checkpointURL = validatedCheckpointURL(
            provider: provider,
            isGuestProfile: profile.kind == .guest,
            storageProfileID: storageProfileID,
            browserStateVault: browserStateVault
        )
        let initialURL = checkpointURL ?? (profile.kind == .saved ? provider.loginURL : nil)
        let store = ChatGPTWebViewStore(
            provider: provider,
            initialURL: initialURL,
            profile: webViewProfile,
            cookieVault: cookieVault,
            browserStateVault: browserStateVault,
            onDetectedDisplayName: { profileID, displayName in
                let normalizedName = displayName
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if navigationLabels.contains(normalizedName) {
                    onDetectedDisplayName(profileID, "Current User")
                    return
                }
                onDetectedDisplayName(profileID, displayName)
            }
        )
        store.updateChatPerformanceConfiguration(chatPerformanceConfiguration)
        store.updateLatestExchangeConfiguration(chatPerformanceConfiguration)
        store.updateChatGPTMobileWebFallback(
            chatPerformanceConfiguration.chatGPTMobileWebFallbackEnabled
        )
        stores[key] = store

        if let checkpointURL {
            enforceCheckpointAfterInitialSessionRestore(
                checkpointURL,
                store: store,
                key: key
            )
        }

        return store
    }

    func updateChatPerformanceConfiguration(_ configuration: ChatPerformanceConfiguration) {
        guard chatPerformanceConfiguration != configuration else {
            return
        }

        chatPerformanceConfiguration = configuration
        for store in stores.values {
            store.updateChatPerformanceConfiguration(configuration)
            store.updateLatestExchangeConfiguration(configuration)
            store.updateChatGPTMobileWebFallback(configuration.chatGPTMobileWebFallbackEnabled)
        }
    }

    func updateRestoreLastChatEnabled(_ isEnabled: Bool) {
        guard restoreLastChatEnabled != isEnabled else { return }

        restoreLastChatEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.restoreLastChatDefaultsKey)

        if isEnabled {
            checkpointAllSessionURLs()
        } else {
            clearSavedSessionURLs()
        }
    }

    func developerSourceSessions() -> [DeveloperWebViewSession] {
        stores.compactMap { key, store in
            guard store.webView.url != nil else { return nil }

            let normalizedProfileID = key.profileID.lowercased()
            let profileLabel: String
            if normalizedProfileID.contains("guest") {
                profileLabel = "Guest"
            } else if normalizedProfileID.contains("primary") || normalizedProfileID.contains("current") {
                profileLabel = "Current User"
            } else {
                profileLabel = "Profile \(String(key.profileID.prefix(8)))"
            }

            return DeveloperWebViewSession(
                id: "\(key.providerID.rawValue)::\(key.profileID)",
                title: "\(store.provider.displayName) • \(profileLabel)",
                webView: store.webView
            )
        }
        .sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func checkpointAllSessionURLs() {
        guard restoreLastChatEnabled else { return }

        for (key, store) in stores {
            checkpointSessionURL(key: key, store: store)
        }
    }

    func persistSession(providerID: AIProviderID, profileID: String) async {
        let key = AIProfileSessionKey(providerID: providerID, profileID: profileID)
        guard let store = stores[key] else { return }
        checkpointSessionURL(key: key, store: store)
        await store.persistProfileSession()
        if !restoreLastChatEnabled {
            clearSavedSessionURLs()
        }
    }

    func persistAllSessions() async {
        checkpointAllSessionURLs()
        for store in stores.values {
            await store.persistProfileSession()
        }
        if !restoreLastChatEnabled {
            clearSavedSessionURLs()
        }
    }

    func setTypingPriority(
        _ isTyping: Bool,
        providerID: AIProviderID,
        profileID: String
    ) {
        let key = AIProfileSessionKey(providerID: providerID, profileID: profileID)
        stores[key]?.setTypingPriority(isTyping)
    }

    func removeSavedProfileSession(providerID: AIProviderID, profileID: String) async {
        let key = AIProfileSessionKey(providerID: providerID, profileID: profileID)
        let storageProfileID = "\(providerID.rawValue)::\(profileID)"
        sessionURLCheckpoint.delete(profileID: storageProfileID)

        guard let store = stores.removeValue(forKey: key) else {
            let cookieVault = ChatGPTProfileCookieVault()
            let browserStateVault = ChatGPTProfileBrowserStateVault()
            cookieVault.delete(profileID: storageProfileID)
            browserStateVault.delete(profileID: storageProfileID)
            if providerID == .chatGPT {
                cookieVault.delete(profileID: profileID)
                browserStateVault.delete(profileID: profileID)
            }
            return
        }

        await store.removeSavedProfileSession()
    }

    func resetGuest(
        provider: AIProvider,
        profile: ChatGPTProfile,
        onDetectedDisplayName: @escaping (String, String) -> Void
    ) async {
        let store = store(
            for: provider,
            profile: profile,
            onDetectedDisplayName: onDetectedDisplayName
        )
        await store.resetGuestSession()
    }

    private func checkpointSessionURL(
        key: AIProfileSessionKey,
        store: ChatGPTWebViewStore
    ) {
        guard restoreLastChatEnabled,
              let url = store.webView.url,
              store.provider.isAuthenticatedContentURL(url) else {
            return
        }

        let storageProfileID = "\(key.providerID.rawValue)::\(key.profileID)"
        sessionURLCheckpoint.save(url, profileID: storageProfileID)
    }

    private func validatedCheckpointURL(
        provider: AIProvider,
        isGuestProfile: Bool,
        storageProfileID: String,
        browserStateVault: ChatGPTProfileBrowserStateVault
    ) -> URL? {
        guard restoreLastChatEnabled, !isGuestProfile else {
            return nil
        }

        guard browserStateVault.shouldRestoreSession(profileID: storageProfileID) else {
            sessionURLCheckpoint.delete(profileID: storageProfileID)
            return nil
        }

        guard let url = sessionURLCheckpoint.url(profileID: storageProfileID) else {
            return nil
        }

        guard provider.isAuthenticatedContentURL(url) else {
            sessionURLCheckpoint.delete(profileID: storageProfileID)
            return nil
        }

        return url
    }

    private func clearSavedSessionURLs() {
        sessionURLCheckpoint.deleteAll()
        ChatGPTProfileBrowserStateVault().clearAllLastURLs()
    }

    private func enforceCheckpointAfterInitialSessionRestore(
        _ checkpointURL: URL,
        store: ChatGPTWebViewStore,
        key: AIProfileSessionKey
    ) {
        Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard let self,
                  self.restoreLastChatEnabled,
                  let store,
                  self.stores[key] === store else {
                return
            }

            guard store.provider.isAuthenticatedContentURL(checkpointURL) else {
                return
            }

            let currentURL = store.webView.url
            guard currentURL?.absoluteString != checkpointURL.absoluteString else {
                return
            }

            // This task exists only for a newly created store. It lets the existing
            // cookie restore begin first, then makes the fast URL checkpoint authoritative
            // when the slower browser-state snapshot still points at an older page.
            store.webView.stopLoading()
            store.webView.load(URLRequest(url: checkpointURL))
        }
    }
}
