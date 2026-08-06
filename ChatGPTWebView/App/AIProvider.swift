import Foundation

enum AIProviderID: String, CaseIterable, Codable, Hashable, Identifiable {
    case chatGPT = "chatgpt"
    case claude
    case gemini
    case grok
    case deepSeek = "deepseek"

    var id: String { rawValue }

    var provider: AIProvider {
        AIProvider.catalog[self]!
    }
}

struct AIProvider: Identifiable, Hashable {
    let id: AIProviderID
    let displayName: String
    let systemImage: String
    let startURL: URL
    let loginURL: URL
    let allowedHostSuffixes: [String]
    let persistentCookieHostSuffixes: [String]
    let authenticatedHostSuffixes: [String]
    let unauthenticatedPathPrefixes: [String]

    var storageNamespace: String {
        id.rawValue
    }

    func allowsHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return allowedHostSuffixes.contains { suffix in
            normalizedHost == suffix || normalizedHost.hasSuffix("." + suffix)
        }
    }

    func isAuthenticatedContentURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              authenticatedHostSuffixes.contains(where: { suffix in
                  host == suffix || host.hasSuffix("." + suffix)
              }) else {
            return false
        }

        if id == .claude, host != "claude.ai" {
            return false
        }

        let path = url.path.lowercased()
        return !unauthenticatedPathPrefixes.contains { path.hasPrefix($0) }
    }

    static let all: [AIProvider] = AIProviderID.allCases.map(\.provider)

    static let catalog: [AIProviderID: AIProvider] = [
        .chatGPT: AIProvider(
            id: .chatGPT,
            displayName: "ChatGPT",
            systemImage: "bubble.left.and.bubble.right.fill",
            startURL: URL(string: "https://chatgpt.com/")!,
            loginURL: URL(string: "https://chatgpt.com/auth/login")!,
            allowedHostSuffixes: [
                "chatgpt.com",
                "openai.com",
                "oaistatic.com",
                "oaiusercontent.com",
                "auth0.com",
                "google.com",
                "gstatic.com",
                "googleusercontent.com",
                "apple.com",
                "icloud.com",
                "microsoft.com",
                "microsoftonline.com",
                "live.com",
                "msauth.net"
            ],
            persistentCookieHostSuffixes: ["chatgpt.com", "openai.com", "auth0.com"],
            authenticatedHostSuffixes: ["chatgpt.com"],
            unauthenticatedPathPrefixes: ["/auth", "/login"]
        ),
        .claude: AIProvider(
            id: .claude,
            displayName: "Claude",
            systemImage: "text.bubble.fill",
            startURL: URL(string: "https://claude.ai/new")!,
            loginURL: URL(string: "https://claude.ai/login")!,
            allowedHostSuffixes: [
                "claude.ai",
                "claude.com",
                "anthropic.com",
                "auth0.com",
                "workos.com",
                "google.com",
                "gstatic.com",
                "googleusercontent.com",
                "apple.com",
                "icloud.com",
                "microsoft.com",
                "microsoftonline.com",
                "live.com",
                "challenges.cloudflare.com"
            ],
            persistentCookieHostSuffixes: ["claude.ai", "claude.com", "anthropic.com", "workos.com"],
            authenticatedHostSuffixes: ["claude.ai"],
            unauthenticatedPathPrefixes: ["/login", "/auth", "/oauth", "/help", "/support"]
        ),
        .gemini: AIProvider(
            id: .gemini,
            displayName: "Gemini",
            systemImage: "diamond.fill",
            startURL: URL(string: "https://gemini.google.com/")!,
            loginURL: URL(string: "https://gemini.google.com/")!,
            allowedHostSuffixes: [
                "gemini.google.com",
                "accounts.google.com",
                "google.com",
                "gstatic.com",
                "googleusercontent.com",
                "googleapis.com"
            ],
            persistentCookieHostSuffixes: ["gemini.google.com", "google.com", "gstatic.com", "googleusercontent.com", "googleapis.com"],
            authenticatedHostSuffixes: ["gemini.google.com"],
            unauthenticatedPathPrefixes: ["/login", "/signin", "/auth"]
        ),
        .grok: AIProvider(
            id: .grok,
            displayName: "Grok",
            systemImage: "bolt.fill",
            startURL: URL(string: "https://grok.com/")!,
            loginURL: URL(string: "https://grok.com/sign-in")!,
            allowedHostSuffixes: [
                "grok.com",
                "x.ai",
                "x.com",
                "twitter.com",
                "twimg.com",
                "grokipedia.com",
                "grokusercontent.com",
                "google.com",
                "gstatic.com",
                "googleusercontent.com",
                "googleapis.com",
                "accounts.youtube.com",
                "apple.com",
                "icloud.com",
                "challenges.cloudflare.com"
            ],
            persistentCookieHostSuffixes: [
                "grok.com",
                "x.ai",
                "x.com",
                "twitter.com",
                "twimg.com",
                "grokipedia.com",
                "grokusercontent.com"
            ],
            authenticatedHostSuffixes: ["grok.com"],
            unauthenticatedPathPrefixes: ["/login", "/signin", "/sign-in", "/auth"]
        ),
        .deepSeek: AIProvider(
            id: .deepSeek,
            displayName: "DeepSeek",
            systemImage: "brain.head.profile",
            startURL: URL(string: "https://chat.deepseek.com/")!,
            loginURL: URL(string: "https://chat.deepseek.com/sign_in")!,
            allowedHostSuffixes: [
                "deepseek.com",
                "google.com",
                "gstatic.com",
                "googleusercontent.com",
                "apple.com",
                "icloud.com",
                "awswaf.com",
                "amazonaws.com"
            ],
            persistentCookieHostSuffixes: ["deepseek.com"],
            authenticatedHostSuffixes: ["chat.deepseek.com"],
            unauthenticatedPathPrefixes: ["/sign_in", "/signin", "/login", "/auth"]
        )
    ]
}
