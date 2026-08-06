import Foundation
import SwiftUI
import WebKit

struct DeveloperWebViewSession {
    let id: String
    let title: String
    let webView: WKWebView
}

struct DeveloperDiscoveredPage: Decodable, Sendable {
    let pageURL: String
    let sources: [DeveloperDiscoveredSource]
}

struct DeveloperDiscoveredSource: Decodable, Sendable {
    let key: String
    let displayName: String
    let url: String?
    let kind: String
    let inlineSource: String?
    let inlineSourceIndex: Int?
    let inlineSourceCharacterCount: Int?

    init(
        key: String,
        displayName: String,
        url: String?,
        kind: String,
        inlineSource: String?,
        inlineSourceIndex: Int? = nil,
        inlineSourceCharacterCount: Int? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.url = url
        self.kind = kind
        self.inlineSource = inlineSource
        self.inlineSourceIndex = inlineSourceIndex
        self.inlineSourceCharacterCount = inlineSourceCharacterCount
    }
}

struct DeveloperSourceFile: Identifiable, Sendable {
    let id: String
    let sessionTitle: String
    let pageURL: String
    let displayName: String
    let urlString: String?
    let kind: String
    let content: String?
    let metadataNote: String?
    let resourceByteCount: Int?
    let loadError: String?

    var byteCount: Int {
        content?.utf8.count ?? resourceByteCount ?? 0
    }
}

struct DeveloperSourceSearchResult: Identifiable, Sendable {
    let source: DeveloperSourceFile
    let matchCount: Int
    let snippets: [String]
    let metadataMatched: Bool

    var id: String {
        source.id
    }
}

struct DeveloperSourceSecondPassInventory: Sendable {
    let externalDescriptors: [DeveloperDiscoveredSource]
    let inlineFiles: [DeveloperSourceFile]
}

enum DeveloperSourceCaptureStage: Int, Sendable {
    case none = 0
    case firstPass = 1
    case secondPass = 2
    case nestedDependencies = 3
    case sourceMapDiscovery = 4
    case sourceMapValidation = 5
    case sourceMaps = 6
}

@MainActor
final class DeveloperSourcesModel: ObservableObject {
    @Published private(set) var results: [DeveloperSourceSearchResult] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isSearching = false
    @Published private(set) var status = "Run Step 1 to capture loaded sources. Later stages remain disabled until the prior stage completes."
    @Published private(set) var snapshotFingerprint: String?
    @Published private(set) var completedStage: DeveloperSourceCaptureStage = .none

    private struct SessionCaptureState {
        let session: DeveloperWebViewSession
        let page: DeveloperDiscoveredPage
        let cookieHeader: String?
        var firstPassFiles: [DeveloperSourceFile]
        var secondPassFiles: [DeveloperSourceFile] = []
        var nestedPassFiles: [DeveloperSourceFile] = []
        var sourceMapCandidates: [DeveloperSourceMapCandidate] = []
        var validatedSourceMaps: [DeveloperValidatedSourceMap] = []
        var sourceMapFiles: [DeveloperSourceFile] = []
    }

    private var sources: [DeveloperSourceFile] = []
    private var captureStates: [SessionCaptureState] = []
    private var captureErrors: [DeveloperSourceFile] = []
    private var captureBudget = DeveloperSourceCaptureBudget()
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var currentQuery = ""

    var hasSources: Bool {
        !sources.isEmpty
    }

    var canRunFirstPass: Bool {
        !isScanning
    }

    var canRunSecondPass: Bool {
        completedStage == .firstPass && !isScanning
    }

    var canRunNestedPass: Bool {
        completedStage == .secondPass && !isScanning
    }

    var canRunSourceMapDiscovery: Bool {
        completedStage == .nestedDependencies && !isScanning
    }

    var canRunSourceMapValidation: Bool {
        completedStage == .sourceMapDiscovery && !isScanning
    }

    var canRunSourceMapDecode: Bool {
        completedStage == .sourceMapValidation && !isScanning
    }

    func archiveSnapshot() -> [DeveloperSourceArchiveItem] {
        sources.map { source in
            DeveloperSourceArchiveItem(
                id: source.id,
                sessionTitle: source.sessionTitle,
                pageURL: source.pageURL,
                displayName: source.displayName,
                urlString: source.urlString,
                kind: source.kind,
                content: source.content,
                metadataNote: source.metadataNote,
                resourceByteCount: source.resourceByteCount,
                loadError: source.loadError
            )
        }
    }

    func markSnapshotFingerprint(_ fingerprint: String) {
        snapshotFingerprint = fingerprint
    }

    func scanIfNeeded(sessions: [DeveloperWebViewSession]) {
        // Capture is deliberately manual. Opening the Dev tab must not start a source pull.
    }

    func scan(sessions: [DeveloperWebViewSession]) {
        runFirstPass(sessions: sessions)
    }

    func runFirstPass(sessions: [DeveloperWebViewSession]) {
        scanTask?.cancel()
        searchTask?.cancel()

        for state in captureStates {
            DeveloperSourceMapStagedRecovery.cleanup(
                candidates: state.sourceMapCandidates,
                validatedMaps: state.validatedSourceMaps
            )
        }

        sources.removeAll(keepingCapacity: false)
        results.removeAll(keepingCapacity: false)
        captureStates.removeAll(keepingCapacity: false)
        captureErrors.removeAll(keepingCapacity: false)
        captureBudget = DeveloperSourceCaptureBudget()
        completedStage = .none
        snapshotFingerprint = nil
        isSearching = false

        guard !sessions.isEmpty else {
            isScanning = false
            status = "No loaded AI browser sessions were found. Open an AI tab, then run Step 1 again."
            return
        }

        beginStage("Step 1: capturing loaded scripts, styles, runtime resources, and bounded inline scripts...")

        scanTask = Task { [weak self] in
            guard let self else { return }
            await DeveloperSourceResponseMetadataRegistry.shared.clear()

            var states: [SessionCaptureState] = []
            var errors: [DeveloperSourceFile] = []

            for session in sessions {
                guard !Task.isCancelled else {
                    self.isScanning = false
                    return
                }

                do {
                    let cookieHeader = await developerCookieHeader(for: session.webView)
                    let page = try await discoverDeveloperSources(in: session.webView)
                    let externalDescriptors = page.sources.filter {
                        $0.inlineSourceIndex == nil && $0.inlineSource == nil && $0.url != nil
                    }
                    let externalFiles = await loadExternalDeveloperSources(
                        externalDescriptors,
                        sessionID: session.id,
                        sessionTitle: session.title,
                        pageURL: page.pageURL,
                        userAgent: session.webView.customUserAgent,
                        cookieHeader: cookieHeader,
                        budget: self.captureBudget
                    )

                    guard !Task.isCancelled else {
                        self.isScanning = false
                        return
                    }

                    self.status = "Step 1: reading inline scripts from \(session.title) in bounded chunks..."
                    let inlineFiles = await loadBudgetedDeveloperInlineSources(
                        from: page.sources,
                        session: session,
                        pageURL: page.pageURL,
                        budget: self.captureBudget
                    )

                    states.append(
                        SessionCaptureState(
                            session: session,
                            page: page,
                            cookieHeader: cookieHeader,
                            firstPassFiles: externalFiles + inlineFiles
                        )
                    )
                } catch {
                    errors.append(self.scanErrorFile(for: session, error: error))
                }

                await Task.yield()
            }

            guard !Task.isCancelled else {
                self.isScanning = false
                return
            }

            self.captureStates = states
            self.captureErrors = errors
            self.completedStage = .firstPass
            await self.finishStage(
                prefix: "Step 1 complete.",
                nextInstruction: "Review the captured sources, then run Step 2 when ready."
            )
        }
    }

    func runSecondPass() {
        guard canRunSecondPass else { return }
        beginStage("Step 2: reconciling late runtime resources and explicit bundler references...")

        scanTask = Task { [weak self] in
            guard let self else { return }
            var updatedStates: [SessionCaptureState] = []

            for var state in self.captureStates {
                guard !Task.isCancelled else {
                    self.isScanning = false
                    return
                }

                let latePage = try? await discoverDeveloperSources(in: state.session.webView)
                let descriptors = DeveloperSourceManualSecondPassScanner.discover(
                    firstPage: state.page,
                    latePage: latePage,
                    firstPassFiles: state.firstPassFiles
                )
                state.secondPassFiles = await loadExternalDeveloperSources(
                    descriptors,
                    sessionID: state.session.id,
                    sessionTitle: state.session.title,
                    pageURL: state.page.pageURL,
                    userAgent: state.session.webView.customUserAgent,
                    cookieHeader: state.cookieHeader,
                    budget: self.captureBudget
                )
                updatedStates.append(state)
                await Task.yield()
            }

            guard !Task.isCancelled else {
                self.isScanning = false
                return
            }

            self.captureStates = updatedStates
            self.completedStage = .secondPass
            await self.finishStage(
                prefix: "Step 2 complete.",
                nextInstruction: "Review the added runtime and bundler sources, then run Step 3 when ready."
            )
        }
    }

    func runNestedPass() {
        guard canRunNestedPass else { return }
        beginStage("Step 3: scanning resolved bundler chunks for one bounded dependency depth...")

        scanTask = Task { [weak self] in
            guard let self else { return }
            var updatedStates: [SessionCaptureState] = []

            for var state in self.captureStates {
                guard !Task.isCancelled else {
                    self.isScanning = false
                    return
                }

                let existingFiles = state.firstPassFiles + state.secondPassFiles
                let descriptors = DeveloperSourceNestedPassScanner.discover(
                    firstPassFiles: state.firstPassFiles,
                    secondPassFiles: state.secondPassFiles,
                    existingFiles: existingFiles
                )
                state.nestedPassFiles = await loadExternalDeveloperSources(
                    descriptors,
                    sessionID: state.session.id,
                    sessionTitle: state.session.title,
                    pageURL: state.page.pageURL,
                    userAgent: state.session.webView.customUserAgent,
                    cookieHeader: state.cookieHeader,
                    budget: self.captureBudget
                )
                updatedStates.append(state)
                await Task.yield()
            }

            guard !Task.isCancelled else {
                self.isScanning = false
                return
            }

            self.captureStates = updatedStates
            self.completedStage = .nestedDependencies
            await self.finishStage(
                prefix: "Step 3 complete.",
                nextInstruction: "Review the nested dependencies, then run Step 4A to discover SourceMaps."
            )
        }
    }

    func runSourceMapDiscovery() {
        guard canRunSourceMapDiscovery else { return }
        beginStage("Step 4A: discovering SourceMap headers, directives, fallback URLs, and captured map resources...")

        scanTask = Task { [weak self] in
            guard let self else { return }
            var updatedStates: [SessionCaptureState] = []
            var candidateCount = 0

            for var state in self.captureStates {
                guard !Task.isCancelled else {
                    self.isScanning = false
                    return
                }

                let inputs = state.firstPassFiles + state.secondPassFiles + state.nestedPassFiles
                state.sourceMapCandidates = await DeveloperSourceMapStagedRecovery.discover(from: inputs)
                state.validatedSourceMaps = []
                state.sourceMapFiles = DeveloperSourceMapStagedRecovery.candidateFiles(
                    state.sourceMapCandidates,
                    sessionID: state.session.id,
                    sessionTitle: state.session.title,
                    pageURL: state.page.pageURL
                )
                candidateCount += state.sourceMapCandidates.count
                updatedStates.append(state)
                await Task.yield()
            }

            guard !Task.isCancelled else {
                self.isScanning = false
                return
            }

            self.captureStates = updatedStates
            self.completedStage = .sourceMapDiscovery
            await self.finishStage(
                prefix: "Step 4A complete. Discovered \(candidateCount) SourceMap candidate\(candidateCount == 1 ? "" : "s").",
                nextInstruction: "Review the candidates, then run Step 4B to validate them one at a time."
            )
        }
    }

    func runSourceMapValidation() {
        guard canRunSourceMapValidation else { return }
        beginStage("Step 4B: downloading and validating one SourceMap at a time, with validated JSON cached to temporary files...")

        scanTask = Task { [weak self] in
            guard let self else { return }
            var updatedStates: [SessionCaptureState] = []
            var validatedCount = 0

            for var state in self.captureStates {
                guard !Task.isCancelled else {
                    self.isScanning = false
                    return
                }

                let inputs = state.firstPassFiles + state.secondPassFiles + state.nestedPassFiles
                state.validatedSourceMaps = await DeveloperSourceMapStagedRecovery.validate(
                    candidates: state.sourceMapCandidates,
                    existingFiles: inputs,
                    sessionID: state.session.id,
                    pageURL: state.page.pageURL,
                    userAgent: state.session.webView.customUserAgent,
                    cookieHeader: state.cookieHeader
                )
                state.sourceMapFiles = DeveloperSourceMapStagedRecovery.validationFiles(
                    state.validatedSourceMaps,
                    sessionID: state.session.id,
                    sessionTitle: state.session.title,
                    pageURL: state.page.pageURL
                )
                validatedCount += state.validatedSourceMaps.count
                updatedStates.append(state)
                await Task.yield()
            }

            guard !Task.isCancelled else {
                self.isScanning = false
                return
            }

            self.captureStates = updatedStates
            self.completedStage = .sourceMapValidation
            await self.finishStage(
                prefix: "Step 4B complete. Validated \(validatedCount) SourceMap\(validatedCount == 1 ? "" : "s").",
                nextInstruction: "Review the validated maps, then run Step 4C to decode embedded original sources."
            )
        }
    }

    func runSourceMapDecode() {
        guard canRunSourceMapDecode else { return }
        beginStage("Step 4C: decoding sourcesContent from one validated SourceMap at a time under the remaining capture budget...")

        scanTask = Task { [weak self] in
            guard let self else { return }
            var updatedStates: [SessionCaptureState] = []
            var mapCount = 0
            var originalCount = 0

            for var state in self.captureStates {
                guard !Task.isCancelled else {
                    self.isScanning = false
                    return
                }

                let recovered = await DeveloperSourceMapStagedRecovery.decode(
                    validatedMaps: state.validatedSourceMaps,
                    sessionID: state.session.id,
                    sessionTitle: state.session.title,
                    pageURL: state.page.pageURL,
                    budget: self.captureBudget
                )
                state.sourceMapFiles = recovered.mapFiles + recovered.originalSourceFiles
                mapCount += recovered.mapFiles.count
                originalCount += recovered.originalSourceFiles.count
                updatedStates.append(state)
                await Task.yield()
            }

            guard !Task.isCancelled else {
                self.isScanning = false
                return
            }

            self.captureStates = updatedStates
            self.completedStage = .sourceMaps
            await self.finishStage(
                prefix: "Step 4C complete. Retained \(mapCount) validated SourceMap\(mapCount == 1 ? "" : "s") and \(originalCount) decoded original source\(originalCount == 1 ? "" : "s").",
                nextInstruction: "The manual source capture is complete. Save the current snapshot to Memory when ready."
            )
        }
    }

    func scheduleSearch(_ query: String) {
        currentQuery = query
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = sources

        guard !trimmedQuery.isEmpty else {
            isSearching = false
            results = snapshot.map {
                DeveloperSourceSearchResult(
                    source: $0,
                    matchCount: 0,
                    snippets: [],
                    metadataMatched: false
                )
            }
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            let searchedResults = await Task.detached(priority: .utility) {
                DeveloperSourceSearchEngine.search(snapshot, query: trimmedQuery)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.results = searchedResults
            self.isSearching = false
        }
    }

    private func beginStage(_ message: String) {
        searchTask?.cancel()
        isSearching = false
        isScanning = true
        snapshotFingerprint = nil
        status = message
    }

    private func finishStage(prefix: String, nextInstruction: String) async {
        let collected = captureStates.flatMap {
            $0.firstPassFiles + $0.secondPassFiles + $0.nestedPassFiles + $0.sourceMapFiles
        } + captureErrors
        let preferred = collected.sorted {
            sourcePreference($0) > sourcePreference($1)
        }
        sources = DeveloperSourceSecondPassScanner.deduplicate(preferred).sorted {
            if $0.sessionTitle == $1.sessionTitle {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.sessionTitle.localizedCaseInsensitiveCompare($1.sessionTitle) == .orderedAscending
        }
        snapshotFingerprint = nil
        isScanning = false

        let budget = await captureBudget.snapshot()
        let retained = ByteCountFormatter.string(
            fromByteCount: Int64(budget.retainedBytes),
            countStyle: .file
        )
        let maximum = ByteCountFormatter.string(
            fromByteCount: Int64(budget.maximumBytes),
            countStyle: .file
        )
        let omitted = budget.omittedTextCount == 0
            ? "No source bodies were omitted by the memory budget."
            : "\(budget.omittedTextCount) source bod\(budget.omittedTextCount == 1 ? "y was" : "ies were") retained as metadata only."

        status = "\(prefix) Indexed \(sources.count) sources. Retained \(retained) of \(maximum). \(omitted) \(nextInstruction)"
        scheduleSearch(currentQuery)
    }

    private func scanErrorFile(
        for session: DeveloperWebViewSession,
        error: Error
    ) -> DeveloperSourceFile {
        DeveloperSourceFile(
            id: "\(session.id)::scan-error",
            sessionTitle: session.title,
            pageURL: session.webView.url?.absoluteString ?? "",
            displayName: "Source inventory unavailable",
            urlString: nil,
            kind: "Scan Error",
            content: nil,
            metadataNote: nil,
            resourceByteCount: nil,
            loadError: error.localizedDescription
        )
    }

    private func sourcePreference(_ source: DeveloperSourceFile) -> Int {
        if source.kind == "Source Map • Validated v3" { return 300 }
        if source.kind == "Original Source • Embedded SourceMap" { return 250 }
        if source.kind == "Source Map Candidate" { return 200 }
        if source.loadError == nil { return 100 }
        return 0
    }
}