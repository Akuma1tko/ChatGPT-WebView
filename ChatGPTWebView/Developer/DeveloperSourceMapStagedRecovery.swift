import Foundation

struct DeveloperSourceMapCandidate: Identifiable, Sendable {
    let id: String
    let reference: String?
    let inlineCacheURL: URL?
    let discovery: String
    let parentSourceID: String
    let parentSourceURL: String?
    let baseURLString: String?
    let displayName: String
    let estimatedByteCount: Int?
}

struct DeveloperValidatedSourceMap: Identifiable, Sendable {
    let id: String
    let candidate: DeveloperSourceMapCandidate
    let mapURLString: String
    let cacheURL: URL
    let byteCount: Int
    let sourceCount: Int
    let generatedFile: String?
    let sourceRoot: String?
}

enum DeveloperSourceMapStagedRecovery {
    static func discover(from files: [DeveloperSourceFile]) async -> [DeveloperSourceMapCandidate] {
        await DeveloperSourceMapDiscoveryEngine.discover(from: files)
    }

    static func candidateFiles(
        _ candidates: [DeveloperSourceMapCandidate],
        sessionID: String,
        sessionTitle: String,
        pageURL: String
    ) -> [DeveloperSourceFile] {
        DeveloperSourceMapDiscoveryEngine.candidateFiles(
            candidates,
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            pageURL: pageURL
        )
    }

    static func validate(
        candidates: [DeveloperSourceMapCandidate],
        existingFiles: [DeveloperSourceFile],
        sessionID: String,
        pageURL: String,
        userAgent: String?,
        cookieHeader: String?
    ) async -> [DeveloperValidatedSourceMap] {
        await DeveloperSourceMapValidationEngine.validate(
            candidates: candidates,
            existingFiles: existingFiles,
            sessionID: sessionID,
            pageURL: pageURL,
            userAgent: userAgent,
            cookieHeader: cookieHeader
        )
    }

    static func validationFiles(
        _ validatedMaps: [DeveloperValidatedSourceMap],
        sessionID: String,
        sessionTitle: String,
        pageURL: String
    ) -> [DeveloperSourceFile] {
        DeveloperSourceMapValidationEngine.validationFiles(
            validatedMaps,
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            pageURL: pageURL
        )
    }

    static func decode(
        validatedMaps: [DeveloperValidatedSourceMap],
        sessionID: String,
        sessionTitle: String,
        pageURL: String,
        budget: DeveloperSourceCaptureBudget
    ) async -> DeveloperSourceMapRecoveryResult {
        await DeveloperSourceMapDecodeEngine.decode(
            validatedMaps: validatedMaps,
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            pageURL: pageURL,
            budget: budget
        )
    }

    static func cleanup(
        candidates: [DeveloperSourceMapCandidate],
        validatedMaps: [DeveloperValidatedSourceMap]
    ) {
        DeveloperSourceMapStageSupport.cleanup(candidates: candidates, validatedMaps: validatedMaps)
    }
}
