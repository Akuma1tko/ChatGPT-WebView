import Foundation

struct SupabaseAppConfig: Codable, Equatable, Sendable {
    var projectURL: URL
    var publishableKey: String

    var memoryFunctionURL: URL {
        projectURL.appendingPathComponent("functions/v1/memory")
    }

    var projectRef: String {
        projectURL.host?
            .split(separator: ".")
            .first
            .map(String.init) ?? projectURL.absoluteString
    }
}

enum SupabaseConfigValidation {
    static func normalize(projectURLText: String, publishableKey: String) throws -> SupabaseAppConfig {
        let trimmedURL = projectURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            throw SupabaseConfigError.missingProjectURL
        }

        guard !trimmedKey.isEmpty else {
            throw SupabaseConfigError.missingPublishableKey
        }

        guard trimmedKey.hasPrefix("sb_publishable_") || trimmedKey.hasPrefix("eyJ") else {
            throw SupabaseConfigError.invalidPublishableKey
        }

        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host != nil else {
            throw SupabaseConfigError.invalidProjectURL
        }

        return SupabaseAppConfig(projectURL: url, publishableKey: trimmedKey)
    }
}

enum SupabaseConfigError: Error, LocalizedError {
    case missingProjectURL
    case missingPublishableKey
    case invalidProjectURL
    case invalidPublishableKey
    case noConfig

    var errorDescription: String? {
        switch self {
        case .missingProjectURL:
            return "Enter your Supabase project URL."
        case .missingPublishableKey:
            return "Enter your Supabase publishable key."
        case .invalidProjectURL:
            return "Use an HTTPS Supabase project URL, such as https://project-ref.supabase.co."
        case .invalidPublishableKey:
            return "Use a Supabase publishable key or legacy anon key. Never use a secret or service role key."
        case .noConfig:
            return "Supabase is not configured yet."
        }
    }
}
