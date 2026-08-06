import CryptoKit
import Foundation

struct DeveloperSourceMapValidationFailure: Sendable {
    let candidate: DeveloperSourceMapCandidate
    let reason: String
}

enum DeveloperSourceMapValidationEvidenceStore {
    private static let lock = NSLock()
    private static var failuresBySessionID: [String: [DeveloperSourceMapValidationFailure]] = [:]

    static func store(_ failures: [DeveloperSourceMapValidationFailure], sessionID: String) {
        lock.lock()
        failuresBySessionID[sessionID] = failures
        lock.unlock()
    }

    static func failures(sessionID: String) -> [DeveloperSourceMapValidationFailure] {
        lock.lock()
        let result = failuresBySessionID[sessionID] ?? []
        lock.unlock()
        return result
    }
}

enum DeveloperSourceMapStageSupport {
    static let maximumParentAssets = 128
    static let maximumMapCandidates = 128
    static let maximumMapBytes = 24 * 1024 * 1024
    static let maximumEncodedInlineMapBytes = 32 * 1024 * 1024
    static let maximumOriginalSources = 1_024
    static let maximumOriginalSourceBytes = 8 * 1024 * 1024

    static func resolvedURLString(for candidate: DeveloperSourceMapCandidate) -> String? {
        guard let reference = candidate.reference else { return nil }
        return resolveReference(reference, relativeTo: candidate.baseURLString.flatMap(URL.init(string:)))
            .flatMap { canonicalURLString($0.absoluteString) }
    }

    static func validationFailureFile(
        _ failure: DeveloperSourceMapValidationFailure,
        sessionID: String,
        sessionTitle: String,
        pageURL: String
    ) -> DeveloperSourceFile {
        let candidate = failure.candidate
        return DeveloperSourceFile(
            id: "\(sessionID)::sourcemap-candidate:\(stableIdentifier(candidate.id))",
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: candidate.displayName,
            urlString: resolvedURLString(for: candidate),
            kind: "Source Map Candidate",
            content: nil,
            metadataNote: "Discovery: \(candidate.discovery)\nStep 4B validation was attempted and the candidate was preserved as evidence.",
            resourceByteCount: candidate.estimatedByteCount,
            loadError: failure.reason
        )
    }

    static func sourceMappingDirectives(in content: String) -> [String] {
        let patterns = [
            #"(?m)//[#@]\s*sourceMappingURL\s*=\s*([^\s]+)\s*$"#,
            #"(?s)/\*#\s*sourceMappingURL\s*=\s*([^*\s]+)\s*\*/"#
        ]
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        var values: [String] = []
        var seen = Set<String>()

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: content, range: range) { match, _, stop in
                guard let match,
                      values.count < maximumMapCandidates,
                      match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else {
                    if values.count >= maximumMapCandidates { stop.pointee = true }
                    return
                }
                let value = nsContent.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` \t\r\n"))
                guard !value.isEmpty, seen.insert(value).inserted else { return }
                values.append(value)
            }
        }
        return values
    }

    static func decodeInlineMapData(_ reference: String) -> Data? {
        guard reference.lowercased().hasPrefix("data:"),
              reference.utf8.count <= maximumEncodedInlineMapBytes,
              let comma = reference.firstIndex(of: ",") else { return nil }
        let metadata = String(reference[reference.index(reference.startIndex, offsetBy: 5)..<comma]).lowercased()
        guard metadata.contains("json") else { return nil }
        let payload = String(reference[reference.index(after: comma)...])
        let data = metadata.contains(";base64")
            ? Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
            : payload.removingPercentEncoding?.data(using: .utf8)
        guard let data, data.count <= maximumMapBytes else { return nil }
        return data
    }

    static func writeTemporaryMapData(_ data: Data, category: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextPortSourceMapStages", isDirectory: true)
            .appendingPathComponent(category, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).map")
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    static func cleanup(candidates: [DeveloperSourceMapCandidate], validatedMaps: [DeveloperValidatedSourceMap]) {
        for candidate in candidates {
            if let url = candidate.inlineCacheURL { try? FileManager.default.removeItem(at: url) }
        }
        for validated in validatedMaps { try? FileManager.default.removeItem(at: validated.cacheURL) }
        cleanupEmptyTemporaryDirectories()
    }

    static func cleanupEmptyTemporaryDirectories() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextPortSourceMapStages", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: child.path)) ?? []
            if entries.isEmpty { try? FileManager.default.removeItem(at: child) }
        }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if remaining.isEmpty { try? FileManager.default.removeItem(at: root) }
    }

    static func isEligibleParent(_ file: DeveloperSourceFile) -> Bool {
        guard file.content != nil,
              let rawURL = file.urlString,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        let path = url.path.lowercased()
        return [".js", ".mjs", ".cjs", ".css"].contains { path.hasSuffix($0) }
    }

    static func fallbackMapURL(for assetURL: URL?) -> URL? {
        guard let assetURL,
              var components = URLComponents(url: assetURL, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        components.path += ".map"
        return components.url
    }

    static func resolveReference(_ raw: String, relativeTo baseURL: URL?) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix("#"),
              !value.lowercased().hasPrefix("blob:"),
              !value.lowercased().hasPrefix("javascript:") else { return nil }
        if let absolute = URL(string: value),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return absolute
        }
        guard let baseURL else { return nil }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    static func canonicalURLString(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        components.fragment = nil
        return components.url?.absoluteString
    }

    static func displayNameForMap(_ raw: String) -> String {
        guard let url = URL(string: raw), !url.lastPathComponent.isEmpty else { return "Inline Source Map" }
        return url.lastPathComponent
    }

    static func displayNameForOriginalSource(_ path: String) -> String {
        let normalized = path
            .replacingOccurrences(of: "webpack:///", with: "")
            .replacingOccurrences(of: "webpack://", with: "")
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let readable = normalized.split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .map(String.init)
            .joined(separator: " › ")
        return readable.isEmpty ? path : readable
    }

    static func stableIdentifier(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
