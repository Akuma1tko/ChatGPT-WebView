import Foundation

enum DeveloperSourceMapDiscoveryEngine {
    static func discover(from files: [DeveloperSourceFile]) async -> [DeveloperSourceMapCandidate] {
        let support = DeveloperSourceMapStageSupport.self
        let parents = Array(files.lazy.filter(support.isEligibleParent).prefix(support.maximumParentAssets))
        let headers = await DeveloperSourceResponseMetadataRegistry.shared.sourceMapReferences(for: parents.map(\.id))
        var candidates: [DeveloperSourceMapCandidate] = []
        var seen = Set<String>()

        func append(_ reference: String, discovery: String, parent: DeveloperSourceFile, baseURL: URL?) {
            guard candidates.count < support.maximumMapCandidates else { return }
            let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            if value.lowercased().hasPrefix("data:") {
                let identity = "inline:\(support.stableIdentifier(value))"
                guard seen.insert(identity).inserted,
                      let data = support.decodeInlineMapData(value),
                      let cacheURL = support.writeTemporaryMapData(data, category: "Candidates") else { return }
                candidates.append(
                    DeveloperSourceMapCandidate(
                        id: identity,
                        reference: nil,
                        inlineCacheURL: cacheURL,
                        discovery: discovery,
                        parentSourceID: parent.id,
                        parentSourceURL: parent.urlString,
                        baseURLString: baseURL?.absoluteString,
                        displayName: "Inline Source Map",
                        estimatedByteCount: data.count
                    )
                )
                return
            }

            guard let resolved = support.resolveReference(value, relativeTo: baseURL),
                  let canonical = support.canonicalURLString(resolved.absoluteString),
                  seen.insert(canonical).inserted else { return }
            candidates.append(
                DeveloperSourceMapCandidate(
                    id: canonical,
                    reference: value,
                    inlineCacheURL: nil,
                    discovery: discovery,
                    parentSourceID: parent.id,
                    parentSourceURL: parent.urlString,
                    baseURLString: baseURL?.absoluteString,
                    displayName: support.displayNameForMap(canonical),
                    estimatedByteCount: nil
                )
            )
        }

        // Prefer browser-observed map resources over guesses.
        for file in files {
            guard candidates.count < support.maximumMapCandidates,
                  let rawURL = file.urlString,
                  let url = URL(string: rawURL),
                  url.path.lowercased().hasSuffix(".map"),
                  let canonical = support.canonicalURLString(rawURL),
                  seen.insert(canonical).inserted else { continue }
            candidates.append(
                DeveloperSourceMapCandidate(
                    id: canonical,
                    reference: canonical,
                    inlineCacheURL: nil,
                    discovery: "captured Source Map resource",
                    parentSourceID: file.id,
                    parentSourceURL: nil,
                    baseURLString: url.absoluteString,
                    displayName: support.displayNameForMap(canonical),
                    estimatedByteCount: file.byteCount > 0 ? file.byteCount : nil
                )
            )
        }

        // Then preserve response-header and sourceMappingURL evidence.
        for parent in parents {
            let baseURL = parent.urlString.flatMap(URL.init(string:))
            for reference in headers[parent.id] ?? [] {
                append(reference, discovery: "SourceMap/X-SourceMap response header", parent: parent, baseURL: baseURL)
            }
            if let content = parent.content {
                for reference in support.sourceMappingDirectives(in: content) {
                    append(reference, discovery: "sourceMappingURL directive", parent: parent, baseURL: baseURL)
                }
            }
        }

        // Finally retain the legacy asset URL + .map probe used by the earlier extractor.
        for parent in parents {
            guard candidates.count < support.maximumMapCandidates else { break }
            let baseURL = parent.urlString.flatMap(URL.init(string:))
            if let fallback = support.fallbackMapURL(for: baseURL) {
                append(fallback.absoluteString, discovery: "legacy asset URL + .map fallback", parent: parent, baseURL: baseURL)
            }
        }

        return candidates
    }

    static func candidateFiles(
        _ candidates: [DeveloperSourceMapCandidate],
        sessionID: String,
        sessionTitle: String,
        pageURL: String
    ) -> [DeveloperSourceFile] {
        candidates.map { candidate in
            DeveloperSourceFile(
                id: "\(sessionID)::sourcemap-candidate:\(DeveloperSourceMapStageSupport.stableIdentifier(candidate.id))",
                sessionTitle: sessionTitle,
                pageURL: pageURL,
                displayName: candidate.displayName,
                urlString: DeveloperSourceMapStageSupport.resolvedURLString(for: candidate),
                kind: "Source Map Candidate",
                content: nil,
                metadataNote: "Discovery: \(candidate.discovery)\nValidation and decoding have not run yet.",
                resourceByteCount: candidate.estimatedByteCount,
                loadError: nil
            )
        }
    }
}
