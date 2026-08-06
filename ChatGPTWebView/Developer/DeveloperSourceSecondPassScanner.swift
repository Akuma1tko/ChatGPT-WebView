import Foundation

enum DeveloperSourceSecondPassScanner {
    private static let maximumSecondPassExternalSources = 512
    private static let maximumInlineDataSources = 64
    private static let maximumDataSourceBytes = 24 * 1024 * 1024

    private struct Candidate {
        let rawReference: String
        let kind: String
        let parentSourceID: String
        let baseURL: URL?
    }

    static func discover(
        firstPage: DeveloperDiscoveredPage,
        latePage: DeveloperDiscoveredPage?,
        firstPassFiles: [DeveloperSourceFile],
        sessionID: String,
        sessionTitle: String,
        pageURL: String
    ) -> DeveloperSourceSecondPassInventory {
        var seenURLs = Set(
            firstPage.sources.compactMap(\.url).compactMap(canonicalURLString)
        )
        var descriptors: [DeveloperDiscoveredSource] = []
        var inlineFiles: [DeveloperSourceFile] = []

        if let latePage {
            for descriptor in latePage.sources where descriptor.inlineSource == nil {
                guard descriptors.count < maximumSecondPassExternalSources,
                      let urlString = descriptor.url,
                      let canonical = canonicalURLString(urlString),
                      !seenURLs.contains(canonical) else {
                    continue
                }

                seenURLs.insert(canonical)
                descriptors.append(
                    DeveloperDiscoveredSource(
                        key: "second-pass:runtime:\(canonical)",
                        displayName: descriptor.displayName,
                        url: canonical,
                        kind: "Second Pass • Late \(descriptor.kind)",
                        inlineSource: nil
                    )
                )
            }
        }

        for file in firstPassFiles {
            guard descriptors.count < maximumSecondPassExternalSources,
                  let content = file.content,
                  !content.isEmpty else {
                continue
            }

            let candidates = referenceCandidates(in: content, source: file)
            for (index, candidate) in candidates.enumerated() {
                if candidate.rawReference.lowercased().hasPrefix("data:") {
                    guard inlineFiles.count < maximumInlineDataSources,
                          let decoded = decodeInlineDataReference(candidate.rawReference) else {
                        continue
                    }

                    inlineFiles.append(
                        DeveloperSourceFile(
                            id: "\(sessionID)::second-pass:inline:\(candidate.parentSourceID):\(index)",
                            sessionTitle: sessionTitle,
                            pageURL: pageURL,
                            displayName: "Inline Source Map \(inlineFiles.count + 1)",
                            urlString: "data:source-map",
                            kind: "Second Pass • Inline Source Map",
                            content: decoded,
                            metadataNote: nil,
                            resourceByteCount: nil,
                            loadError: nil
                        )
                    )
                    continue
                }

                guard descriptors.count < maximumSecondPassExternalSources,
                      let resolved = resolveReference(candidate.rawReference, relativeTo: candidate.baseURL),
                      let canonical = canonicalURLString(resolved.absoluteString),
                      !seenURLs.contains(canonical),
                      isSourceLikeURL(resolved) else {
                    continue
                }

                seenURLs.insert(canonical)
                descriptors.append(
                    DeveloperDiscoveredSource(
                        key: "second-pass:reference:\(canonical)",
                        displayName: displayName(for: resolved, fallback: "Referenced Source"),
                        url: canonical,
                        kind: "Second Pass • \(candidate.kind)",
                        inlineSource: nil
                    )
                )
            }
        }

        return DeveloperSourceSecondPassInventory(
            externalDescriptors: descriptors,
            inlineFiles: inlineFiles
        )
    }

    static func deduplicate(_ files: [DeveloperSourceFile]) -> [DeveloperSourceFile] {
        var seenIDs = Set<String>()
        var seenURLSessionPairs = Set<String>()
        var result: [DeveloperSourceFile] = []

        for file in files {
            guard !seenIDs.contains(file.id) else { continue }

            if let urlString = file.urlString,
               let canonical = canonicalURLString(urlString),
               !urlString.lowercased().hasPrefix("data:") {
                let pair = "\(file.sessionTitle)\u{1F}\(canonical)"
                guard !seenURLSessionPairs.contains(pair) else { continue }
                seenURLSessionPairs.insert(pair)
            }

            seenIDs.insert(file.id)
            result.append(file)
        }

        return result
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
            (#"sourceMappingURL\s*=\s*([^\s*]+)"#, "Source Map"),
            (#"new\s+(?:Shared)?Worker\s*\(\s*[\"']([^\"']+)[\"']"#, "Worker JavaScript"),
            (#"importScripts\s*\(\s*[\"']([^\"']+)[\"']"#, "Imported Worker Script"),
            (#"import\s*\(\s*[\"']([^\"']+)[\"']\s*\)"#, "Dynamic JavaScript"),
            (#"(?:import|export)\s+(?:[^\"']*?\s+from\s+)?[\"']([^\"']+)[\"']"#, "Module JavaScript"),
            (#"new\s+URL\s*\(\s*[\"']([^\"']+\.(?:m?js|cjs|css|map|wasm)(?:\?[^\"']*)?)[\"']"#, "URL Source"),
            (#"[\"']((?:https?:)?//[^\"']+\.(?:m?js|cjs|css|map|wasm)(?:\?[^\"']*)?)[\"']"#, "Absolute Referenced Source")
        ]

        for (pattern, kind) in patterns {
            guard candidates.count < 2_048,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            regex.enumerateMatches(in: content, options: [], range: fullRange) { match, _, stop in
                guard let match,
                      match.numberOfRanges > 1,
                      candidates.count < 2_048 else {
                    if candidates.count >= 2_048 {
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

        for candidate in bundlerRuntimeCandidates(in: content, source: source) {
            let key = "\(candidate.kind)\u{1F}\(candidate.rawReference)"
            guard candidates.count < 2_048,
                  !seen.contains(key) else {
                continue
            }
            seen.insert(key)
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
            for match in regex.matches(in: content, options: [], range: fullRange) {
                guard match.numberOfRanges > 5 else { continue }

                let runtimeName = nsContent.substring(with: match.range(at: 1))
                let prefix = nsContent.substring(with: match.range(at: 3))
                let names = objectMap(nsContent.substring(with: match.range(at: 4)))
                let hashes = objectMap(nsContent.substring(with: match.range(at: 5)))
                let publicPath = runtimePublicPath(runtimeName, in: content)
                let runtimeBaseURL = bundlerBaseURL(
                    publicPath: publicPath,
                    sourceBaseURL: sourceBaseURL
                )

                for chunkID in referencedChunkIDs.sorted() {
                    let key = String(chunkID)
                    guard let hash = hashes[key] else { continue }

                    let name = names[key] ?? key
                    let path = "\(prefix)\(name).\(hash).js"
                    let kind = workerChunkIDs.contains(chunkID)
                        ? "Bundler Worker Chunk"
                        : "Bundler JavaScript Chunk"

                    candidates.append(
                        Candidate(
                            rawReference: path,
                            kind: kind,
                            parentSourceID: source.id,
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
            for match in regex.matches(in: content, options: [], range: fullRange) {
                guard match.numberOfRanges > 5 else { continue }

                let runtimeName = nsContent.substring(with: match.range(at: 1))
                let prefix = nsContent.substring(with: match.range(at: 3))
                let names = objectMap(nsContent.substring(with: match.range(at: 4)))
                let hashes = objectMap(nsContent.substring(with: match.range(at: 5)))
                let publicPath = runtimePublicPath(runtimeName, in: content)
                let runtimeBaseURL = bundlerBaseURL(
                    publicPath: publicPath,
                    sourceBaseURL: sourceBaseURL
                )

                for chunkID in referencedChunkIDs.sorted() {
                    let key = String(chunkID)
                    guard let name = names[key],
                          let hash = hashes[key] else {
                        continue
                    }

                    candidates.append(
                        Candidate(
                            rawReference: "\(prefix)\(name).\(hash).css",
                            kind: "Bundler Stylesheet",
                            parentSourceID: source.id,
                            baseURL: runtimeBaseURL
                        )
                    )
                }
            }
        }

        return candidates
    }

    private static func numericCaptures(
        in content: String,
        pattern: String
    ) -> Set<Int> {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var values = Set<Int>()

        for match in regex.matches(in: content, options: [], range: fullRange) {
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
            pattern: #"(\d+):[\"']([^\"']+)[\"']"#,
            options: []
        ) else {
            return [:]
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var values: [String: String] = [:]

        for match in regex.matches(in: content, options: [], range: fullRange) {
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

    private static func runtimePublicPath(
        _ runtimeName: String,
        in content: String
    ) -> String? {
        let escapedRuntimeName = NSRegularExpression.escapedPattern(for: runtimeName)
        guard let regex = try? NSRegularExpression(
            pattern: escapedRuntimeName + #"\.p\s*=\s*[\"']([^\"']+)[\"']"#,
            options: []
        ) else {
            return nil
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        guard let match = regex.matches(in: content, options: [], range: fullRange).last,
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }

        return nsContent.substring(with: match.range(at: 1))
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

    private static func decodeInlineDataReference(_ raw: String) -> String? {
        guard raw.lowercased().hasPrefix("data:"),
              let comma = raw.firstIndex(of: ",") else {
            return nil
        }

        let metadata = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]).lowercased()
        guard metadata.contains("json") || metadata.contains("javascript") || metadata.contains("text") else {
            return nil
        }

        let payload = String(raw[raw.index(after: comma)...])
        let data: Data?
        if metadata.contains(";base64") {
            data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }

        guard let data,
              data.count <= maximumDataSourceBytes else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
