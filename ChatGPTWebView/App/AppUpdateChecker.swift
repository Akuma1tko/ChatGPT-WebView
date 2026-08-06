import Foundation

struct AppUpdate: Identifiable {
    let version: String
    let currentVersion: String
    let releaseURL: URL

    var id: String { version }
}

private struct GitHubLatestRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    @Published var availableUpdate: AppUpdate?
    @Published var checkForUpdatesOnStart: Bool {
        didSet {
            UserDefaults.standard.set(checkForUpdatesOnStart, forKey: Self.checkOnStartKey)
        }
    }

    private static let checkOnStartKey = "CheckForUpdatesOnStart"
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/DeerSpotter/ContextPort/releases/latest")!

    init() {
        if UserDefaults.standard.object(forKey: Self.checkOnStartKey) == nil {
            checkForUpdatesOnStart = true
        } else {
            checkForUpdatesOnStart = UserDefaults.standard.bool(forKey: Self.checkOnStartKey)
        }
    }

    func checkForUpdateOnStartup() async {
        guard checkForUpdatesOnStart else {
            return
        }

        await checkForUpdate()
    }

    func checkForUpdate() async {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        do {
            var request = URLRequest(
                url: latestReleaseURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 8
            )
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ContextPort-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
            let latestVersion = normalizedVersion(release.tagName)

            guard isVersion(latestVersion, newerThan: currentVersion) else {
                return
            }

            availableUpdate = AppUpdate(
                version: latestVersion,
                currentVersion: currentVersion,
                releaseURL: release.htmlURL
            )
        } catch {
            // Update checks are best effort and must never block app startup.
        }
    }

    private func normalizedVersion(_ value: String) -> String {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        return version
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = numericVersionParts(candidate)
        let currentParts = numericVersionParts(current)
        let count = max(candidateParts.count, currentParts.count)

        for index in 0..<count {
            let candidateValue = index < candidateParts.count ? candidateParts[index] : 0
            let currentValue = index < currentParts.count ? currentParts[index] : 0

            if candidateValue > currentValue {
                return true
            }
            if candidateValue < currentValue {
                return false
            }
        }

        return false
    }

    private func numericVersionParts(_ value: String) -> [Int] {
        normalizedVersion(value)
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
