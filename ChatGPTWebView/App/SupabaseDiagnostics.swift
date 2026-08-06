import Foundation

struct SupabaseDiagnosticResult: Identifiable, Equatable {
    enum Status: String {
        case pass = "Pass"
        case warning = "Warning"
        case fail = "Fail"
    }

    let id = UUID()
    let name: String
    let status: Status
    let detail: String
}

actor SupabaseDiagnosticsClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func run(projectURLText: String, publishableKey: String) async -> [SupabaseDiagnosticResult] {
        var results: [SupabaseDiagnosticResult] = []

        let config: SupabaseAppConfig
        do {
            config = try SupabaseConfigValidation.normalize(
                projectURLText: projectURLText,
                publishableKey: publishableKey
            )
            results.append(.init(name: "Local config", status: .pass, detail: "Project URL and publishable key format look valid."))
        } catch {
            results.append(.init(name: "Local config", status: .fail, detail: error.localizedDescription))
            return results
        }

        results.append(await checkAuthSettings(config: config))
        results.append(await checkMemoryFunction(config: config))

        return results
    }

    private func checkAuthSettings(config: SupabaseAppConfig) async -> SupabaseDiagnosticResult {
        let url = config.projectURL.appendingPathComponent("auth/v1/settings")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .init(name: "Auth settings", status: .fail, detail: "No HTTP response from Supabase Auth.")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                return .init(name: "Auth settings", status: .fail, detail: "Supabase Auth returned HTTP \(httpResponse.statusCode). Check the project URL and publishable key.")
            }

            let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let external = settings?["external"] as? [String: Any]
            let enabledProviders = external?
                .filter { _, value in
                    if let enabled = value as? Bool { return enabled }
                    return false
                }
                .map { $0.key }
                .sorted() ?? []

            if enabledProviders.isEmpty {
                return .init(name: "Auth providers", status: .warning, detail: "Project is reachable, but no social providers appear enabled yet. Email/password may still work if enabled.")
            }

            return .init(name: "Auth providers", status: .pass, detail: "Enabled providers: \(enabledProviders.joined(separator: ", ")).")
        } catch {
            return .init(name: "Auth settings", status: .fail, detail: error.localizedDescription)
        }
    }

    private func checkMemoryFunction(config: SupabaseAppConfig) async -> SupabaseDiagnosticResult {
        var request = URLRequest(url: config.memoryFunctionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "list_projects"])

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .init(name: "Memory function", status: .fail, detail: "No HTTP response from the memory function.")
            }

            switch httpResponse.statusCode {
            case 200..<300:
                return .init(name: "Memory function", status: .pass, detail: "Memory function responded successfully.")
            case 401, 403:
                return .init(name: "Memory function", status: .pass, detail: "Memory function exists and is protected by JWT, which is expected before login.")
            case 404:
                return .init(name: "Memory function", status: .fail, detail: "Memory function was not found. Deploy `supabase/functions/memory` to this project.")
            default:
                return .init(name: "Memory function", status: .warning, detail: "Memory function returned HTTP \(httpResponse.statusCode). It may exist, but setup should be checked.")
            }
        } catch {
            return .init(name: "Memory function", status: .fail, detail: error.localizedDescription)
        }
    }
}
