import Foundation

enum DeveloperSourceNestedPassScanner {
    private static let maximumNestedExternalSources = 128

    private struct Candidate {
        let rawReference: String
        let kind: String
        let parentSourceID: String
        let baseURL: URL?
    }

    static func discover(
        firstPassFiles: [DeveloperSourceFile],
        secondPassFiles: [DeveloperSourceFile],
        existingFiles: [DeveloperSourceFile]
    ) -> [DeveloperDiscoveredSource] {
        let eligibleKinds: Set<String> = [
            "Second Pass • Bundler JavaScript Chunk",
            "Second Pass • Bundler Worker Chunk"
        ]
        let runtimeBases = runtimeBaseURLs(in: firstPassFiles)
        var seenURLs = Set(
            existingFiles.compactMap(\.urlString).compactMap(canonicalURLString)
        )
        var descriptors: [DeveloperDiscoveredSource] = []

        for file in secondPassFiles where eligibleKinds.contains(file.kind) {
            guard descriptors.count < maximumNestedExternalSources,
                  let content = file.content,
                  !content.isEmpty else {
                continue
            }

            let runtimeBase = bestRuntimeBaseURL(for: file, candidates: runtimeBases)
            let candidates = strictNestedReferenceCandidates(
                in: content,
                source: file,
                runtimeBaseURL: runtimeBase
            )

            for candidate in candidates {
                guard descriptors.count < maximumNestedExternalSources,
                      let resolved = resolveReference(candidate.rawReference, relativeTo: candidate.baseURL),
                      let canonical = canonicalURLString(resolved.absoluteString),
                      !seenURLs.contains(canonical),
                      isSourceLikeURL(resolved) else {
                    continue
                }

                seenURLs.insert(canonical)
                descriptors.append(
                    DeveloperDiscoveredSource(
                        key: "nested-pass:reference:\(canonical)",
                        displayName: displayName(for: resolved, fallback: "Nested Dependency"),
                        url: canonical,
                        kind: "Nested Pass • \(candidate.kind)",
                        inlineSource: nil
                    )
                )
            }
        }

        return descriptors
    }

    private static func strictNestedReferenceCandidates(
        in content: String,
        source: DeveloperSourceFile,
        runtimeBaseURL: URL?
    ) -> [Candidate] {
        let sourceBaseURL = source.urlString.flatMap(URL.init(string:))
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var candidates: [Candidate] = []
        var seen = Set<String>()

        let patterns: [(String, String, URL?)] = [
            (#"sourceMappingURL\s*=\s*([^\s*]+)"#, "Source Map", sourceBaseURL),
            (#"new\s+(?:Shared)?Worker\s*\(\s*[\"']([^\"']+)[\"']"#, "Worker JavaScript", sourceBaseURL),
            (#"importScripts\s*\(\s*[\"']([^\"']+)[\"']"#, "Imported Worker Script", sourceBaseURL),
            (#"import\s*\(\s*[\"']([^\"']+)[\"']\s*\)"#, "Dynamic JavaScript", sourceBaseURL),
            (#"(?:import|export)\s+(?:[^\"']*?\s+from\s+)?[\"']([^\"']+)[\"']"#, "Module JavaScript", sourceBaseURL),
            (#"new\s+URL\s*\(\s*[\"']([^\"']+\.(?:m?js|cjs|css|map|wasm)(?:\?[^\"']*)?)[\"']"#, "URL Source", sourceBaseURL),
            (#"\b[A-Za-z_$][A-Za-z0-9_$]*\.p\s*\+\s*[\"']([^\"']+\.(?:m?js|cjs|css|map|wasm)(?:\?[^\"']*)?)[\"']"#, "Bundler Runtime Asset", runtimeBaseURL)
        ]

        for (pattern, kind, baseURL) in patterns {
            guard candidates.count < 512,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            regex.enumerateMatches(in: content, options: [], range: fullRange) { match, _, stop in
                guard let match,
                      match.numberOfRanges > 1,
                      candidates.count < 512 else {
                    if candidates.count >= 512 {
                        stop.pointee = true
                    }
                    return
                }

                let range = match.range(at: 1)
                guard range.location != NSNotFound else { return }

                let raw = nsContent.substring(with: range)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
                guard !raw.isEmpty else { return }

                let key = "\(kind)\u{1F}\(raw)"
                guard !seen.contains(key) else { return }
                seen.insert(key)
                candidates.append(
                    Candidate(
                        rawReference: raw,
                        kind: kind,
                        parentSourceID: source.id,
                        baseURL: baseURL
                    )
                )
            }
        }

        return candidates
    }

    private static func runtimeBaseURLs(in files: [DeveloperSourceFile]) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b[A-Za-z_$][A-Za-z0-9_$]*\.p\s*=\s*[\"']([^\"']+)[\"']"#,
            options: []
        ) else {
            return []
        }

        var result: [URL] = []
        var seen = Set<String>()

        for file in files {
            guard let content = file.content else { continue }
            let sourceBaseURL = file.urlString.flatMap(URL.init(string:))
            let nsContent = content as NSString
            let fullRange = NSRange(location: 0, length: nsContent.length)

            for match in regex.matches(in: content, options: [], range: fullRange) {
                guard match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else {
                    continue
                }

                let publicPath = nsContent.substring(with: match.range(at: 1))
                guard let baseURL = bundlerBaseURL(
                    publicPath: publicPath,
                    sourceBaseURL: sourceBaseURL
                ),
                let canonical = canonicalURLString(baseURL.absoluteString),
                !seen.contains(canonical),
                let canonicalURL = URL(string: canonical) else {
                    continue
                }

                seen.insert(canonical)
                result.append(canonicalURL)
            }
        }

        return result
    }

    private static func bestRuntimeBaseURL(
        for file: DeveloperSourceFile,
        candidates: [URL]
    ) -> URL? {
        guard let sourceURL = file.urlString.flatMap(URL.init(string:)) else {
            return candidates.count == 1 ? candidates.first : nil
        }

        let sameHost = candidates.filter {
            $0.host?.caseInsensitiveCompare(sourceURL.host ?? "") == .orderedSame
        }
        let prefixMatches = sameHost.filter { sourceURL.path.hasPrefix($0.path) }

        if let best = prefixMatches.max(by: { $0.path.count < $1.path.count }) {
            return best
        }
        if sameHost.count == 1 {
            return sameHost.first
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func bundlerBaseURL(
        publicPath: String?,
        sourceBaseURL: URL?
    ) -> URL? {
        guard let publicPath, !publicPath.isEmpty else {
            return sourceBaseURL
        }

        if let absolute = URL(string: publicPath),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return absolute
        }

        return URL(string: publicPath, relativeTo: sourceBaseURL)?.absoluteURL
            ?? sourceBaseURL
    }

    private static func resolveReference(_ raw: String, relativeTo baseURL: URL?) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.lowercased().hasPrefix("blob:"),
              !trimmed.lowercased().hasPrefix("javascript:") else {
            return nil
        }

        if let absolute = URL(string: trimmed),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return absolute
        }

        guard let baseURL else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private static func isSourceLikeURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let path = url.path.lowercased()
        return [".js", ".mjs", ".cjs", ".css", ".map", ".wasm"].contains {
            path.hasSuffix($0)
        }
    }

    private static func canonicalURLString(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func displayName(for url: URL, fallback: String) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? fallback : name
    }
}
