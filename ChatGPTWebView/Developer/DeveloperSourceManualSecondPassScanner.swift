import Foundation

enum DeveloperSourceManualSecondPassScanner {
    private static let maximumExternalSources = 128
    private static let maximumCandidatesPerSource = 512

    private struct Candidate {
        let rawReference: String
        let kind: String
        let baseURL: URL?
    }

    static func discover(
        firstPage: DeveloperDiscoveredPage,
        latePage: DeveloperDiscoveredPage?,
        firstPassFiles: [DeveloperSourceFile]
    ) -> [DeveloperDiscoveredSource] {
        var seenURLs = Set(firstPage.sources.compactMap(\.url).compactMap(canonicalURLString))
        var descriptors: [DeveloperDiscoveredSource] = []

        if let latePage {
            for descriptor in latePage.sources {
                guard descriptors.count < maximumExternalSources,
                      descriptor.inlineSourceIndex == nil,
                      descriptor.inlineSource == nil,
                      let urlString = descriptor.url,
                      let canonical = canonicalURLString(urlString),
                      seenURLs.insert(canonical).inserted else {
                    continue
                }

                descriptors.append(
                    DeveloperDiscoveredSource(
                        key: "manual-second-pass:runtime:\(canonical)",
                        displayName: descriptor.displayName,
                        url: canonical,
                        kind: "Second Pass • Late \(descriptor.kind)",
                        inlineSource: nil
                    )
                )
            }
        }

        for file in firstPassFiles {
            guard descriptors.count < maximumExternalSources,
                  let content = file.content,
                  !content.isEmpty else {
                continue
            }

            for candidate in referenceCandidates(in: content, source: file) {
                guard descriptors.count < maximumExternalSources,
                      !candidate.rawReference.lowercased().hasPrefix("data:"),
                      let resolved = resolveReference(candidate.rawReference, relativeTo: candidate.baseURL),
                      let canonical = canonicalURLString(resolved.absoluteString),
                      isSourceLikeURL(resolved),
                      seenURLs.insert(canonical).inserted else {
                    continue
                }

                descriptors.append(
                    DeveloperDiscoveredSource(
                        key: "manual-second-pass:reference:\(canonical)",
                        displayName: displayName(for: resolved, fallback: "Referenced Source"),
                        url: canonical,
                        kind: "Second Pass • \(candidate.kind)",
                        inlineSource: nil
                    )
                )
            }
        }

        return descriptors
    }

    private static func referenceCandidates(
        in content: String,
        source: DeveloperSourceFile
    ) -> [Candidate] {
        let baseURL = source.urlString.flatMap(URL.init(string:))
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var candidates: [Candidate] = []
        var seen = Set<String>()

        let patterns: [(String, String)] = [
            (#"(?m)//[#@]\s*sourceMappingURL\s*=\s*([^\s]+)\s*$"#, "Source Map"),
            (#"(?s)/\*#\s*sourceMappingURL\s*=\s*([^*\s]+)\s*\*/"#, "Source Map"),
            (#"new\s+(?:Shared)?Worker\s*\(\s*[\"']([^\"']+)[\"']"#, "Worker JavaScript"),
            (#"importScripts\s*\(\s*[\"']([^\"']+)[\"']"#, "Imported Worker Script"),
            (#"import\s*\(\s*[\"']([^\"']+)[\"']\s*\)"#, "Dynamic JavaScript"),
            (#"(?:import|export)\s+(?:[^\"']*?\s+from\s+)?[\"']([^\"']+)[\"']"#, "Module JavaScript"),
            (#"new\s+URL\s*\(\s*[\"']([^\"']+\.(?:m?js|cjs|css|map|wasm)(?:\?[^\"']*)?)[\"']"#, "URL Source"),
            (#"[\"']((?:https?:)?//[^\"']+\.(?:m?js|cjs|css|map|wasm)(?:\?[^\"']*)?)[\"']"#, "Absolute Referenced Source")
        ]

        for (pattern, kind) in patterns {
            guard candidates.count < maximumCandidatesPerSource,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            regex.enumerateMatches(in: content, range: fullRange) { match, _, stop in
                guard let match,
                      match.numberOfRanges > 1,
                      candidates.count < maximumCandidatesPerSource else {
                    if candidates.count >= maximumCandidatesPerSource {
                        stop.pointee = true
                    }
                    return
                }

                let range = match.range(at: 1)
                guard range.location != NSNotFound else { return }
                let raw = nsContent.substring(with: range)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` \t\r\n"))
                guard !raw.isEmpty else { return }

                let key = "\(kind)\u{1F}\(raw)"
                guard seen.insert(key).inserted else { return }
                candidates.append(Candidate(rawReference: raw, kind: kind, baseURL: baseURL))
            }
        }

        for candidate in bundlerRuntimeCandidates(in: content, source: source) {
            let key = "\(candidate.kind)\u{1F}\(candidate.rawReference)"
            guard candidates.count < maximumCandidatesPerSource,
                  seen.insert(key).inserted else {
                continue
            }
            candidates.append(candidate)
        }

        return candidates
    }

    private static func bundlerRuntimeCandidates(
        in content: String,
        source: DeveloperSourceFile
    ) -> [Candidate] {
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let sourceBaseURL = source.urlString.flatMap(URL.init(string:))
        let referencedChunkIDs = numericCaptures(
            in: content,
            pattern: #"\.(?:u|e)\(\s*(\d+)\s*\)"#
        )
        let workerChunkIDs = numericCaptures(
            in: content,
            pattern: #"new\s+(?:Shared)?Worker\s*\(\s*new\s+URL\s*\([^)]*?\.u\(\s*(\d+)\s*\)"#
        )

        guard !referencedChunkIDs.isEmpty else { return [] }
        var candidates: [Candidate] = []

        let javascriptRuntimePattern = #"([A-Za-z_$][A-Za-z0-9_$]*)\.u=([A-Za-z_$][A-Za-z0-9_$]*)=>[\"']([^\"']*)[\"']\+\(\(\{(.*?)\}\)\[\2\]\|\|\2\)\+[\"']\.[\"']\+\(\{(.*?)\}\)\[\2\]\+[\"']\.js[\"']"#
        if let regex = try? NSRegularExpression(
            pattern: javascriptRuntimePattern,
            options: [.dotMatchesLineSeparators]
        ) {
            for match in regex.matches(in: content, range: fullRange) {
                guard match.numberOfRanges > 5 else { continue }
                let runtimeName = nsContent.substring(with: match.range(at: 1))
                let prefix = nsContent.substring(with: match.range(at: 3))
                let names = objectMap(nsContent.substring(with: match.range(at: 4)))
                let hashes = objectMap(nsContent.substring(with: match.range(at: 5)))
                let runtimeBaseURL = bundlerBaseURL(
                    publicPath: runtimePublicPath(runtimeName, in: content),
                    sourceBaseURL: sourceBaseURL
                )

                for chunkID in referencedChunkIDs.sorted() {
                    let key = String(chunkID)
                    guard let hash = hashes[key] else { continue }
                    let name = names[key] ?? key
                    candidates.append(
                        Candidate(
                            rawReference: "\(prefix)\(name).\(hash).js",
                            kind: workerChunkIDs.contains(chunkID)
                                ? "Bundler Worker Chunk"
                                : "Bundler JavaScript Chunk",
                            baseURL: runtimeBaseURL
                        )
                    )
                }
            }
        }

        let stylesheetRuntimePattern = #"([A-Za-z_$][A-Za-z0-9_$]*)\.k=([A-Za-z_$][A-Za-z0-9_$]*)=>[\"']([^\"']*)[\"']\+\(\{(.*?)\}\)\[\2\]\+[\"']\.[\"']\+\(\{(.*?)\}\)\[\2\]\+[\"']\.css[\"']"#
        if let regex = try? NSRegularExpression(
            pattern: stylesheetRuntimePattern,
            options: [.dotMatchesLineSeparators]
        ) {
            for match in regex.matches(in: content, range: fullRange) {
                guard match.numberOfRanges > 5 else { continue }
                let runtimeName = nsContent.substring(with: match.range(at: 1))
                let prefix = nsContent.substring(with: match.range(at: 3))
                let names = objectMap(nsContent.substring(with: match.range(at: 4)))
                let hashes = objectMap(nsContent.substring(with: match.range(at: 5)))
                let runtimeBaseURL = bundlerBaseURL(
                    publicPath: runtimePublicPath(runtimeName, in: content),
                    sourceBaseURL: sourceBaseURL
                )

                for chunkID in referencedChunkIDs.sorted() {
                    let key = String(chunkID)
                    guard let name = names[key], let hash = hashes[key] else { continue }
                    candidates.append(
                        Candidate(
                            rawReference: "\(prefix)\(name).\(hash).css",
                            kind: "Bundler Stylesheet",
                            baseURL: runtimeBaseURL
                        )
                    )
                }
            }
        }

        return candidates
    }

    private static func numericCaptures(in content: String, pattern: String) -> Set<Int> {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        var values = Set<Int>()
        for match in regex.matches(in: content, range: range) {
            guard match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound,
                  let value = Int(nsContent.substring(with: match.range(at: 1))) else {
                continue
            }
            values.insert(value)
        }
        return values
    }

    private static func objectMap(_ content: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d+):[\"']([^\"']+)[\"']"#
        ) else {
            return [:]
        }
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        var values: [String: String] = [:]
        for match in regex.matches(in: content, range: range) {
            guard match.numberOfRanges > 2,
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: 2).location != NSNotFound else {
                continue
            }
            values[nsContent.substring(with: match.range(at: 1))] =
                nsContent.substring(with: match.range(at: 2))
        }
        return values
    }

    private static func runtimePublicPath(_ runtimeName: String, in content: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: runtimeName)
        guard let regex = try? NSRegularExpression(
            pattern: #"\b"# + escaped + #"\.p\s*=\s*[\"']([^\"']+)[\"']"#
        ) else {
            return nil
        }
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        guard let match = regex.firstMatch(in: content, range: range),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return nsContent.substring(with: match.range(at: 1))
    }

    private static func bundlerBaseURL(publicPath: String?, sourceBaseURL: URL?) -> URL? {
        guard let publicPath, !publicPath.isEmpty else { return sourceBaseURL }
        if let absolute = URL(string: publicPath),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return absolute
        }
        return URL(string: publicPath, relativeTo: sourceBaseURL)?.absoluteURL ?? sourceBaseURL
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
        url.lastPathComponent.isEmpty ? fallback : url.lastPathComponent
    }
}
