import Foundation

enum ChatGPTProfileSessionStatus: String, Codable {
    case active
    case loggedOut
}

struct ChatGPTProfileOriginBrowserState: Codable {
    var localStorage: [String: String]
}

struct ChatGPTProfileBrowserState: Codable {
    var origins: [String: ChatGPTProfileOriginBrowserState]
    var lastURL: String?
    var capturedAt: Date
    var sessionStatus: ChatGPTProfileSessionStatus?

    static let empty = ChatGPTProfileBrowserState(
        origins: [:],
        lastURL: nil,
        capturedAt: .distantPast,
        sessionStatus: nil
    )
}

final class ChatGPTProfileBrowserStateVault {
    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        directoryURL = baseURL
            .appendingPathComponent("ChatGPTWebView", isDirectory: true)
            .appendingPathComponent("ProfileBrowserState", isDirectory: true)

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func load(profileID: String) -> ChatGPTProfileBrowserState {
        let url = fileURL(profileID: profileID)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ChatGPTProfileBrowserState.self, from: data) else {
            return .empty
        }
        return state
    }

    func shouldRestoreSession(profileID: String) -> Bool {
        load(profileID: profileID).sessionStatus != .loggedOut
    }

    func migrateLegacyProfileIfNeeded(legacyProfileID: String, profileID: String) {
        guard legacyProfileID != profileID else { return }

        let legacyURL = fileURL(profileID: legacyProfileID)
        let newURL = fileURL(profileID: profileID)
        guard !fileManager.fileExists(atPath: newURL.path),
              fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }

        try? fileManager.copyItem(at: legacyURL, to: newURL)
    }

    func save(
        origin: String,
        localStorage: [String: String],
        lastURL: String?,
        profileID: String
    ) {
        guard !origin.isEmpty else { return }

        var state = load(profileID: profileID)
        guard state.sessionStatus != .loggedOut else { return }

        state.origins[origin] = ChatGPTProfileOriginBrowserState(localStorage: localStorage)
        state.lastURL = lastURL ?? state.lastURL
        state.capturedAt = Date()
        state.sessionStatus = .active
        write(state, profileID: profileID)
    }

    func markLoggedOut(profileID: String) {
        let state = ChatGPTProfileBrowserState(
            origins: [:],
            lastURL: nil,
            capturedAt: Date(),
            sessionStatus: .loggedOut
        )
        write(state, profileID: profileID)
    }

    func markActive(profileID: String) {
        var state = load(profileID: profileID)
        state.sessionStatus = .active
        state.capturedAt = Date()
        write(state, profileID: profileID)
    }

    func lastURL(profileID: String) -> URL? {
        lastURL(
            profileID: profileID,
            allowedHostSuffixes: AIProviderID.chatGPT.provider.authenticatedHostSuffixes
        )
    }

    func lastURL(profileID: String, allowedHostSuffixes: [String]) -> URL? {
        let state = load(profileID: profileID)
        guard state.sessionStatus != .loggedOut,
              let value = state.lastURL,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHostSuffixes.contains(where: { suffix in
                  host == suffix || host.hasSuffix("." + suffix)
              }) else {
            return nil
        }
        return url
    }

    func documentStartRestoreScript(
        profileID: String,
        overwriteExistingValues: Bool = true
    ) -> String? {
        let state = load(profileID: profileID)
        guard state.sessionStatus != .loggedOut else { return nil }

        let states = state.origins.mapValues(\.localStorage)
        guard !states.isEmpty,
              let data = try? JSONEncoder().encode(states),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        let shouldOverwrite = overwriteExistingValues ? "true" : "false"

        return """
        (() => {
          const statesByOrigin = \(json);
          const overwriteExistingValues = \(shouldOverwrite);
          try {
            const values = statesByOrigin[window.location.origin];
            if (!values) return;
            for (const [key, value] of Object.entries(values)) {
              try {
                if (overwriteExistingValues || window.localStorage.getItem(key) === null) {
                  window.localStorage.setItem(key, value);
                }
              } catch (_) {}
            }
          } catch (_) {}
        })();
        """
    }

    func clearAllLastURLs() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in files where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  var state = try? JSONDecoder().decode(ChatGPTProfileBrowserState.self, from: data),
                  state.lastURL != nil else {
                continue
            }

            state.lastURL = nil
            guard let updatedData = try? JSONEncoder().encode(state) else { continue }
            try? updatedData.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    func delete(profileID: String) {
        try? fileManager.removeItem(at: fileURL(profileID: profileID))
    }

    private func write(_ state: ChatGPTProfileBrowserState, profileID: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(
            to: fileURL(profileID: profileID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func fileURL(profileID: String) -> URL {
        let safeID = profileID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directoryURL.appendingPathComponent("\(safeID).json", isDirectory: false)
    }
}
