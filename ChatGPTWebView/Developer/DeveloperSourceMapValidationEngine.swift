import Foundation

enum DeveloperSourceMapValidationEngine {
    private struct ValidationDocument: Decodable {
        let version: Int
        let file: String?
        let sourceRoot: String?
        let sources: [String]
        let mappings: String
    }

    private struct LoadedCandidateData {
        let mapURLString: String
        let data: Data
    }

    private enum CandidateLoadFailure: LocalizedError {
        case inlineCacheUnavailable
        case invalidReference
        case httpStatus(Int)
        case responseTooLarge(Int?)
        case requestFailed(String)
        case invalidSourceMap
        case temporaryCacheFailed

        var errorDescription: String? {
            switch self {
            case .inlineCacheUnavailable:
                return "The inline SourceMap payload could not be reopened for validation."
            case .invalidReference:
                return "The SourceMap reference could not be resolved to an HTTP or HTTPS URL."
            case .httpStatus(let code):
                return "SourceMap request returned HTTP \(code)."
            case .responseTooLarge(let bytes):
                return bytes.map { "SourceMap response exceeded the 24 MB validation limit at \($0) bytes." }
                    ?? "SourceMap response exceeded the 24 MB validation limit."
            case .requestFailed(let message):
                return "SourceMap request failed: \(message)"
            case .invalidSourceMap:
                return "The response did not validate as a version 3 SourceMap with sources and mappings."
            case .temporaryCacheFailed:
                return "The validated SourceMap could not be staged to temporary storage for Step 4C."
            }
        }
    }

    static func validate(
        candidates: [DeveloperSourceMapCandidate],
        existingFiles: [DeveloperSourceFile],
        sessionID: String,
        pageURL: String,
        userAgent: String?,
        cookieHeader: String?
    ) async -> [DeveloperValidatedSourceMap] {
        let support = DeveloperSourceMapStageSupport.self
        var existingByURL: [String: DeveloperSourceFile] = [:]
        for file in existingFiles {
            guard let rawURL = file.urlString,
                  let canonical = support.canonicalURLString(rawURL) else { continue }
            if let existing = existingByURL[canonical] {
                if existing.content == nil, file.content != nil { existingByURL[canonical] = file }
            } else {
                existingByURL[canonical] = file
            }
        }

        var validated: [DeveloperValidatedSourceMap] = []
        var failures: [DeveloperSourceMapValidationFailure] = []

        for candidate in candidates.prefix(support.maximumMapCandidates) {
            guard !Task.isCancelled else { break }
            defer {
                if let url = candidate.inlineCacheURL { try? FileManager.default.removeItem(at: url) }
            }

            switch await loadCandidateData(
                candidate,
                existingByURL: existingByURL,
                pageURL: pageURL,
                userAgent: userAgent,
                cookieHeader: cookieHeader
            ) {
            case .failure(let error):
                failures.append(.init(candidate: candidate, reason: error.localizedDescription))
            case .success(let loaded):
                guard let document = decodeValidationDocument(loaded.data) else {
                    failures.append(.init(candidate: candidate, reason: CandidateLoadFailure.invalidSourceMap.localizedDescription))
                    continue
                }
                guard let cacheURL = support.writeTemporaryMapData(loaded.data, category: "Validated") else {
                    failures.append(.init(candidate: candidate, reason: CandidateLoadFailure.temporaryCacheFailed.localizedDescription))
                    continue
                }
                validated.append(
                    DeveloperValidatedSourceMap(
                        id: "\(sessionID)::validated-sourcemap:\(support.stableIdentifier(loaded.mapURLString))",
                        candidate: candidate,
                        mapURLString: loaded.mapURLString,
                        cacheURL: cacheURL,
                        byteCount: loaded.data.count,
                        sourceCount: document.sources.count,
                        generatedFile: document.file,
                        sourceRoot: document.sourceRoot
                    )
                )
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        DeveloperSourceMapValidationEvidenceStore.store(failures, sessionID: sessionID)
        return validated
    }

    static func validationFiles(
        _ validatedMaps: [DeveloperValidatedSourceMap],
        sessionID: String,
        sessionTitle: String,
        pageURL: String
    ) -> [DeveloperSourceFile] {
        let support = DeveloperSourceMapStageSupport.self
        let validFiles = validatedMaps.map { validated -> DeveloperSourceFile in
            let metadata = [
                "Discovery: \(validated.candidate.discovery)",
                validated.candidate.parentSourceURL.map { "Parent Source URL: \($0)" },
                "Validated SourceMap: version 3",
                "Original source paths: \(validated.sourceCount)",
                validated.generatedFile.map { "Generated File: \($0)" },
                validated.sourceRoot.map { "Source Root: \($0)" },
                "Embedded sourcesContent decoding is pending Step 4C."
            ].compactMap { $0 }.joined(separator: "\n")
            return DeveloperSourceFile(
                id: "\(sessionID)::safe-sourcemap:\(support.stableIdentifier(validated.mapURLString))",
                sessionTitle: sessionTitle,
                pageURL: pageURL,
                displayName: support.displayNameForMap(validated.mapURLString),
                urlString: support.canonicalURLString(validated.mapURLString),
                kind: "Source Map • Validated v3",
                content: nil,
                metadataNote: metadata,
                resourceByteCount: validated.byteCount,
                loadError: nil
            )
        }
        let failedFiles = DeveloperSourceMapValidationEvidenceStore.failures(sessionID: sessionID).map {
            support.validationFailureFile($0, sessionID: sessionID, sessionTitle: sessionTitle, pageURL: pageURL)
        }
        return validFiles + failedFiles
    }

    private static func loadCandidateData(
        _ candidate: DeveloperSourceMapCandidate,
        existingByURL: [String: DeveloperSourceFile],
        pageURL: String,
        userAgent: String?,
        cookieHeader: String?
    ) async -> Result<LoadedCandidateData, CandidateLoadFailure> {
        let support = DeveloperSourceMapStageSupport.self
        if let cacheURL = candidate.inlineCacheURL {
            guard let data = try? Data(contentsOf: cacheURL, options: [.mappedIfSafe]),
                  data.count <= support.maximumMapBytes else { return .failure(.inlineCacheUnavailable) }
            return .success(.init(
                mapURLString: "inline-source-map:\(candidate.parentSourceURL ?? candidate.parentSourceID)",
                data: data
            ))
        }

        guard let reference = candidate.reference,
              let resolved = support.resolveReference(reference, relativeTo: candidate.baseURLString.flatMap(URL.init(string:))),
              let canonical = support.canonicalURLString(resolved.absoluteString) else {
            return .failure(.invalidReference)
        }

        if let existing = existingByURL[canonical], let content = existing.content {
            let data = Data(content.utf8)
            if data.count <= support.maximumMapBytes { return .success(.init(mapURLString: canonical, data: data)) }
        }

        do {
            var request = URLRequest(url: resolved)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            if let cookieHeader, !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
            request.setValue(pageURL, forHTTPHeaderField: "Referer")

            let loaded = try await DeveloperSourceBoundedRequest(maximumBytes: support.maximumMapBytes).load(request)
            if let response = loaded.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                return .failure(.httpStatus(response.statusCode))
            }
            return .success(.init(mapURLString: canonical, data: loaded.data))
        } catch let error as DeveloperSourceBoundedLoadError {
            return .failure(.responseTooLarge(error.byteCount))
        } catch {
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    private static func decodeValidationDocument(_ data: Data) -> ValidationDocument? {
        guard data.count <= DeveloperSourceMapStageSupport.maximumMapBytes,
              let document = try? JSONDecoder().decode(ValidationDocument.self, from: data),
              document.version == 3,
              !document.sources.isEmpty,
              document.mappings.count > 10 else { return nil }
        return document
    }
}
