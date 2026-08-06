import Foundation

struct SupabaseSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let email: String?
}

enum SupabaseAuthClientError: Error, LocalizedError {
    case invalidResponse
    case noSession
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Supabase Auth returned an invalid response."
        case .noSession:
            return "No saved Supabase session is available."
        case .serverError(let message):
            return message
        }
    }
}

enum SupabaseOAuthProvider: String, CaseIterable, Identifiable, Sendable {
    case github
    case google
    case apple
    case azure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github:
            return "GitHub"
        case .google:
            return "Google"
        case .apple:
            return "Apple"
        case .azure:
            return "Microsoft"
        }
    }
}

actor SupabaseAuthClient {
    private let projectURL: URL
    private let publishableKey: String
    private let session: URLSession

    init(projectURL: URL, publishableKey: String, session: URLSession = .shared) {
        self.projectURL = projectURL
        self.publishableKey = publishableKey
        self.session = session
    }

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        let url = projectURL.appendingPathComponent("auth/v1/token")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]

        return try await postAuth(
            url: components.url!,
            body: [
                "email": email,
                "password": password
            ]
        )
    }

    func signUp(email: String, password: String) async throws -> SupabaseSession {
        let url = projectURL.appendingPathComponent("auth/v1/signup")
        return try await postAuth(
            url: url,
            body: [
                "email": email,
                "password": password
            ]
        )
    }

    func refreshSession(refreshToken: String) async throws -> SupabaseSession {
        let url = projectURL.appendingPathComponent("auth/v1/token")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

        return try await postAuth(
            url: components.url!,
            body: [
                "refresh_token": refreshToken
            ]
        )
    }

    func oauthAuthorizationURL(provider: SupabaseOAuthProvider, redirectTo: URL) throws -> URL {
        let url = projectURL.appendingPathComponent("auth/v1/authorize")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirectTo.absoluteString)
        ]

        guard let authURL = components.url else {
            throw SupabaseAuthClientError.invalidResponse
        }

        return authURL
    }

    func session(fromOAuthCallback callbackURL: URL) throws -> SupabaseSession {
        var values: [String: String] = [:]

        if let fragment = callbackURL.fragment {
            URLComponents(string: "callback://callback?\(fragment)")?.queryItems?.forEach { item in
                values[item.name] = item.value
            }
        }

        URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.forEach { item in
            values[item.name] = item.value
        }

        if let errorDescription = values["error_description"] ?? values["error"] {
            throw SupabaseAuthClientError.serverError(errorDescription.replacingOccurrences(of: "+", with: " "))
        }

        guard let accessToken = values["access_token"],
              let refreshToken = values["refresh_token"] else {
            throw SupabaseAuthClientError.serverError("OAuth callback did not include a Supabase session. Check that the provider is enabled and the redirect URL is allowlisted.")
        }

        let expiresIn = values["expires_in"].flatMap(TimeInterval.init) ?? 3600
        let email = values["email"]

        return SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: email
        )
    }

    private func postAuth(url: URL, body: [String: Any]) async throws -> SupabaseSession {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAuthClientError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            if let payload = try? JSONDecoder().decode(AuthErrorPayload.self, from: data) {
                throw SupabaseAuthClientError.serverError(payload.message ?? payload.errorDescription ?? payload.error ?? "Supabase Auth failed.")
            }
            throw SupabaseAuthClientError.serverError("Supabase Auth failed with HTTP \(httpResponse.statusCode).")
        }

        let payload = try JSONDecoder().decode(AuthSessionPayload.self, from: data)
        return SupabaseSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            email: payload.user?.email
        )
    }
}

private struct AuthSessionPayload: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: AuthUserPayload?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}

private struct AuthUserPayload: Decodable {
    let email: String?
}

private struct AuthErrorPayload: Decodable {
    let error: String?
    let message: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case message
        case errorDescription = "error_description"
    }
}
