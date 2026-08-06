import Foundation

enum DeveloperSourceMapDecodeEngine {
    private struct DecodeDocument: Decodable {
        let version: Int
        let file: String?
        let sourceRoot: String?
        let sources: [String]
        let sourcesContent: [String?]?
        let mappings: String
    }

    static func decode(
        validatedMaps: [DeveloperValidatedSourceMap],
        sessionID: String,
        sessionTitle: String,
        pageURL: String,
        budget: DeveloperSourceCaptureBudget
    ) async -> DeveloperSourceMapRecoveryResult {
        let support = DeveloperSourceMapStageSupport.self
        var mapFiles = DeveloperSourceMapValidationEvidenceStore.failures(sessionID: sessionID).map {
            support.validationFailureFile($0, sessionID: sessionID, sessionTitle: sessionTitle, pageURL: pageURL)
        }
        var originalFiles: [DeveloperSourceFile] = []

        for validated in validatedMaps {
            guard !Task.isCancelled else { break }
            defer { try? FileManager.default.removeItem(at: validated.cacheURL) }

            guard let data = try? Data(contentsOf: validated.cacheURL, options: [.mappedIfSafe]),
                  data.count <= support.maximumMapBytes,
                  let document = decodeDocument(data) else {
                let failure = DeveloperSourceMapValidationFailure(
                    candidate: validated.candidate,
                    reason: "The validated SourceMap cache could not be reopened or fully decoded during Step 4C."
                )
                mapFiles.append(
                    support.validationFailureFile(
                        failure,
                        sessionID: sessionID,
                        sessionTitle: sessionTitle,
                        pageURL: pageURL
                    )
                )
                continue
            }

            let embeddedCount = document.sourcesContent?.compactMap { $0 }.count ?? 0
            let metadata = [
                "Discovery: \(validated.candidate.discovery)",
                validated.candidate.parentSourceURL.map { "Parent Source URL: \($0)" },
                "Validated SourceMap: version 3",
                "Embedded sources: \(document.sources.count)",
                "Embedded sourcesContent entries: \(embeddedCount)",
                embeddedCount > 0
                    ? "Retention: validated map JSON is metadata-only because sourcesContent was decoded into original source entries."
                    : nil
            ].compactMap { $0 }.joined(separator: "\n")

            if embeddedCount == 0, let text = String(data: data, encoding: .utf8) {
                let reservation = await budget.reserve(upTo: data.count)
                if reservation == data.count {
                    await budget.commit(reservation: reservation, actualBytes: data.count)
                    mapFiles.append(mapFile(validated, sessionID, sessionTitle, pageURL, text, metadata, nil))
                } else {
                    await budget.release(reservation: reservation, countAsOmission: true)
                    mapFiles.append(mapFile(
                        validated,
                        sessionID,
                        sessionTitle,
                        pageURL,
                        nil,
                        metadata + "\nRetention: map text exceeded the remaining shared capture budget and was retained as metadata only.",
                        data.count
                    ))
                }
            } else {
                mapFiles.append(mapFile(validated, sessionID, sessionTitle, pageURL, nil, metadata, data.count))
            }

            guard let contents = document.sourcesContent else { continue }
            for (index, path) in document.sources.enumerated() {
                guard originalFiles.count < support.maximumOriginalSources,
                      index < contents.count,
                      let content = contents[index],
                      !content.isEmpty else { continue }

                let sourceBytes = content.utf8.count
                let sourceMetadata = [
                    "SourceMap URL: \(validated.mapURLString)",
                    validated.candidate.parentSourceURL.map { "Parent Source URL: \($0)" },
                    "Original Source Path: \(path)",
                    document.sourceRoot.map { "Source Root: \($0)" },
                    document.file.map { "Generated File: \($0)" }
                ].compactMap { $0 }.joined(separator: "\n")

                if sourceBytes > support.maximumOriginalSourceBytes {
                    await budget.recordOmission()
                    originalFiles.append(originalFile(
                        validated,
                        index,
                        path,
                        sessionID,
                        sessionTitle,
                        pageURL,
                        nil,
                        sourceMetadata + "\nRetention: original source text exceeded the restored 8 MB per-source limit and was retained as metadata only.",
                        sourceBytes
                    ))
                    continue
                }

                let reservation = await budget.reserve(upTo: sourceBytes)
                if reservation == sourceBytes {
                    await budget.commit(reservation: reservation, actualBytes: sourceBytes)
                    originalFiles.append(originalFile(
                        validated, index, path, sessionID, sessionTitle, pageURL, content, sourceMetadata, nil
                    ))
                } else {
                    await budget.release(reservation: reservation, countAsOmission: true)
                    originalFiles.append(originalFile(
                        validated,
                        index,
                        path,
                        sessionID,
                        sessionTitle,
                        pageURL,
                        nil,
                        sourceMetadata + "\nRetention: original source text exceeded the remaining shared capture budget and was retained as metadata only.",
                        sourceBytes
                    ))
                }
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        support.cleanupEmptyTemporaryDirectories()
        return DeveloperSourceMapRecoveryResult(mapFiles: mapFiles, originalSourceFiles: originalFiles)
    }

    private static func decodeDocument(_ data: Data) -> DecodeDocument? {
        guard data.count <= DeveloperSourceMapStageSupport.maximumMapBytes,
              let document = try? JSONDecoder().decode(DecodeDocument.self, from: data),
              document.version == 3,
              !document.sources.isEmpty,
              document.mappings.count > 10 else { return nil }
        return document
    }

    private static func mapFile(
        _ validated: DeveloperValidatedSourceMap,
        _ sessionID: String,
        _ sessionTitle: String,
        _ pageURL: String,
        _ content: String?,
        _ metadata: String,
        _ byteCount: Int?
    ) -> DeveloperSourceFile {
        let support = DeveloperSourceMapStageSupport.self
        return DeveloperSourceFile(
            id: "\(sessionID)::safe-sourcemap:\(support.stableIdentifier(validated.mapURLString))",
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: support.displayNameForMap(validated.mapURLString),
            urlString: support.canonicalURLString(validated.mapURLString),
            kind: "Source Map • Validated v3",
            content: content,
            metadataNote: metadata,
            resourceByteCount: byteCount,
            loadError: nil
        )
    }

    private static func originalFile(
        _ validated: DeveloperValidatedSourceMap,
        _ index: Int,
        _ path: String,
        _ sessionID: String,
        _ sessionTitle: String,
        _ pageURL: String,
        _ content: String?,
        _ metadata: String,
        _ byteCount: Int?
    ) -> DeveloperSourceFile {
        let support = DeveloperSourceMapStageSupport.self
        return DeveloperSourceFile(
            id: "\(sessionID)::safe-original:\(support.stableIdentifier(validated.mapURLString)):\(index)",
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            displayName: support.displayNameForOriginalSource(path),
            urlString: nil,
            kind: "Original Source • Embedded SourceMap",
            content: content,
            metadataNote: metadata,
            resourceByteCount: byteCount,
            loadError: nil
        )
    }
}
