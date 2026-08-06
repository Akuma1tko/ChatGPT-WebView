import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var authEmail: String?
    @Published var statusMessage = ""
    @Published var projects: [MemoryProject] = []
    @Published var selectedProject: MemoryProject?
    @Published var searchResults: [MemoryItem] = []
    @Published var localMemoryEntries: [LocalMemoryEntry] = []
    @Published var localMemorySearchResults: [LocalMemoryEntry] = []
    @Published var localRenderedContext = ""
    @Published var pendingLocalStartContext: String?
    @Published var openChatGPTTabRequestID = UUID()
    @Published var diagnostics: [SupabaseDiagnosticResult] = []
    @Published private(set) var lastVirtualMCPResult: VirtualMCPSaveContextResult?
    @Published private(set) var lastSessionImportResult: SessionContextImportResult?
    @Published private(set) var lastLocalMemorySave: LocalMemorySaveResult?
    @Published var isBusy = false

    let configStore = SupabaseConfigStore()
    let virtualMCPRegistry = VirtualMCPToolRegistry.memoryPrototype

    private let callbackScheme = "chatgptwebview"
    private let callbackURL = URL(string: "chatgptwebview://auth-callback")!
    private let tokenStore = TokenStore()
    private let oauthSession = OAuthWebAuthenticationSession()
    private let diagnosticsClient = SupabaseDiagnosticsClient()
    private let localMemoryStore = LocalMemoryStore()
    private let defaultProjectName = "ChatGPT-WebView"
    private let defaultProjectDescription = "Default memory project for ChatGPT WebView."

    init() {
        reloadLocalMemory()
    }

    func restoreSession() async {
        reloadLocalMemory()

        guard self.configStore.config != nil else {
            self.statusMessage = localMemoryEntries.isEmpty
                ? "Add your Supabase project URL and publishable key, or use Local Vault offline."
                : "Local Vault loaded. Supabase setup is optional."
            return
        }

        guard let session = self.tokenStore.load() else {
            self.isAuthenticated = false
            self.authEmail = nil
            return
        }

        self.isAuthenticated = true
        self.authEmail = session.email
        self.statusMessage = "Signed in as \(session.email ?? "stored session")"
        await self.refreshProjects(autoCreateDefault: true)
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == callbackScheme else {
            return
        }

        guard url.host?.lowercased() == "setup" else {
            return
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let projectURLText = items.first(where: { $0.name == "url" })?.value ?? ""
        let publishableKey = items.first(where: { $0.name == "key" })?.value ?? ""

        self.saveConfig(projectURLText: projectURLText, publishableKey: publishableKey)
        self.statusMessage = "Imported Supabase setup link. Run diagnostics, then log in."
    }

    func saveConfig(projectURLText: String, publishableKey: String) {
        do {
            try self.configStore.save(projectURLText: projectURLText, publishableKey: publishableKey)
            self.signOut(clearConfig: false)
            self.statusMessage = "Supabase project saved. Now log in."
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    func clearConfig() {
        self.signOut(clearConfig: true)
        self.diagnostics = []
        self.statusMessage = "Supabase project config cleared. Local Vault remains on this device."
    }

    func runDiagnostics(projectURLText: String, publishableKey: String) async {
        self.isBusy = true
        self.statusMessage = "Running Supabase diagnostics..."
        defer { self.isBusy = false }

        self.diagnostics = await diagnosticsClient.run(
            projectURLText: projectURLText,
            publishableKey: publishableKey
        )

        let failed = self.diagnostics.filter { $0.status == .fail }.count
        let warnings = self.diagnostics.filter { $0.status == .warning }.count

        if failed > 0 {
            self.statusMessage = "Diagnostics found \(failed) failure(s)."
        } else if warnings > 0 {
            self.statusMessage = "Diagnostics passed with \(warnings) warning(s)."
        } else {
            self.statusMessage = "Diagnostics passed."
        }
    }

    func runSavedDiagnostics() async {
        guard let config = self.configStore.config else {
            self.statusMessage = SupabaseConfigError.noConfig.localizedDescription
            return
        }

        await self.runDiagnostics(
            projectURLText: config.projectURL.absoluteString,
            publishableKey: config.publishableKey
        )
    }

    func setupDeepLink(projectURLText: String, publishableKey: String) -> String? {
        guard let config = try? SupabaseConfigValidation.normalize(projectURLText: projectURLText, publishableKey: publishableKey) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = "setup"
        components.queryItems = [
            URLQueryItem(name: "url", value: config.projectURL.absoluteString),
            URLQueryItem(name: "key", value: config.publishableKey)
        ]

        return components.url?.absoluteString
    }

    func signIn(email: String, password: String) async {
        await runBusy("Signing in...") { [self] in
            let session = try await self.authClient().signIn(email: email, password: password)
            self.applySignedInSession(session, message: "Signed in.")
            try await self.loadProjects(autoCreateDefault: true)
        }
    }

    func signUp(email: String, password: String) async {
        await runBusy("Creating account...") { [self] in
            let session = try await self.authClient().signUp(email: email, password: password)
            self.applySignedInSession(session, message: "Account created and signed in.")
            try await self.loadProjects(autoCreateDefault: true)
        }
    }

    func signInWithOAuth(provider: SupabaseOAuthProvider) async {
        await runBusy("Opening \(provider.title) login...") { [self] in
            let authorizationURL = try await self.authClient().oauthAuthorizationURL(
                provider: provider,
                redirectTo: self.callbackURL
            )

            let callbackURL = try await self.oauthSession.start(
                url: authorizationURL,
                callbackScheme: self.callbackScheme
            )

            let session = try await self.authClient().session(fromOAuthCallback: callbackURL)
            self.applySignedInSession(session, message: "Logged in with \(provider.title).")
            try await self.loadProjects(autoCreateDefault: true)
        }
    }

    func signOut(clearConfig: Bool = false) {
        self.tokenStore.clear()
        self.isAuthenticated = false
        self.authEmail = nil
        self.projects = []
        self.selectedProject = nil
        self.searchResults = []
        self.lastVirtualMCPResult = nil
        self.lastSessionImportResult = nil
        if clearConfig {
            self.configStore.clear()
        }
        self.statusMessage = "Logged out. Local Vault remains on this device."
    }

    func refreshProjects(autoCreateDefault: Bool = false) async {
        await runBusy(autoCreateDefault ? "Loading memory project..." : "Loading projects...") { [self] in
            try await self.loadProjects(autoCreateDefault: autoCreateDefault)
        }
    }

    func createProject(name: String, description: String) async {
        await runBusy("Creating project...") { [self] in
            let project = try await self.memoryClient().createProject(name: name, description: description)
            self.selectedProject = project
            try await self.loadProjects(autoCreateDefault: false)
            self.statusMessage = "Created project: \(project.name)"
        }
    }

    func saveMemory(title: String, content: String, tags: String) async {
        guard let selectedProject = self.selectedProject else {
            self.statusMessage = "Create or select a project first."
            return
        }

        await runBusy("Saving memory...") { [self] in
            let tagList = self.parseCommaSeparatedList(tags)

            _ = try await self.memoryClient().saveMemory(
                projectID: selectedProject.id,
                title: title,
                content: content,
                tags: tagList
            )
            self.statusMessage = "Saved memory."
        }
    }

    func searchMemory(query: String) async {
        guard let selectedProject = self.selectedProject else {
            self.statusMessage = "Create or select a project first."
            return
        }

        await runBusy("Searching memory...") { [self] in
            self.searchResults = try await self.memoryClient().searchMemory(projectID: selectedProject.id, query: query)
            self.statusMessage = "Found \(self.searchResults.count) result(s)."
        }
    }

    func reloadLocalMemory() {
        do {
            self.localMemoryEntries = try localMemoryStore.loadEntries()
            if localMemorySearchResults.isEmpty {
                self.localMemorySearchResults = Array(localMemoryEntries.prefix(10))
            }
        } catch {
            self.statusMessage = "Local Vault load failed: \(error.localizedDescription)"
        }
    }

    func saveLocalSessionContext(
        title: String,
        content: String,
        source: String,
        tagsText: String,
        importance: Int
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            self.statusMessage = "Local save requires a title."
            return
        }

        guard !trimmedContent.isEmpty else {
            self.statusMessage = "Paste session context before saving locally."
            return
        }

        do {
            let projectName = selectedProject?.name ?? defaultProjectName
            let result = try localMemoryStore.saveEntry(
                projectName: projectName,
                title: trimmedTitle,
                content: trimmedContent,
                source: source,
                tags: parseCommaSeparatedList(tagsText),
                importance: importance
            )
            self.lastLocalMemorySave = result
            self.localMemoryEntries = try localMemoryStore.loadEntries()
            self.localMemorySearchResults = Array(localMemoryEntries.prefix(10))
            self.statusMessage = result.message
        } catch {
            self.statusMessage = "Local save failed: \(error.localizedDescription)"
        }
    }

    func searchLocalMemory(query: String) {
        do {
            self.localMemorySearchResults = try localMemoryStore.search(query)
            self.statusMessage = "Found \(localMemorySearchResults.count) local result(s)."
        } catch {
            self.statusMessage = "Local search failed: \(error.localizedDescription)"
        }
    }

    func renderLocalProjectContext() {
        do {
            let projectName = selectedProject?.name ?? defaultProjectName
            self.localRenderedContext = try localMemoryStore.renderProjectContext(projectName: projectName)
            self.statusMessage = "Rendered local project context."
        } catch {
            self.statusMessage = "Local context render failed: \(error.localizedDescription)"
        }
    }

    func localPDFURL(for entry: LocalMemoryEntry) -> URL? {
        localMemoryStore.pdfURL(for: entry)
    }

    func startNewChat(using entry: LocalMemoryEntry) {
        let context = localMemoryStore.startNewChatContext(for: entry)
        self.pendingLocalStartContext = context
        UIPasteboard.general.string = context
        self.openChatGPTTabRequestID = UUID()
        self.statusMessage = "Prepared saved context for a new chat. Paste it into ChatGPT to begin."
    }

    func clearPendingLocalStartContext() {
        self.pendingLocalStartContext = nil
    }

    func runVirtualSaveContextAfterApproval(
        title: String,
        summary: String,
        decisionsText: String,
        openTasksText: String,
        filesDiscussedText: String,
        nextStepsText: String,
        tagsText: String,
        importance: Int
    ) async {
        let proposal = VirtualMCPSaveContextProposal(
            projectID: self.selectedProject?.id,
            title: title,
            summary: summary,
            decisions: self.parseLineSeparatedList(decisionsText),
            openTasks: self.parseLineSeparatedList(openTasksText),
            filesDiscussed: self.parseLineSeparatedList(filesDiscussedText),
            nextSteps: self.parseLineSeparatedList(nextStepsText),
            tags: self.parseCommaSeparatedList(tagsText),
            importance: importance
        )

        await self.runVirtualSaveContextAfterApproval(proposal: proposal)
    }

    func runVirtualSaveContextAfterApproval(proposal: VirtualMCPSaveContextProposal) async {
        let fallbackProjectID = self.selectedProject?.id
        guard let projectID = proposal.projectID ?? fallbackProjectID else {
            self.statusMessage = "Create or select a project before running save_context_after_approval."
            return
        }

        guard !proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.statusMessage = "save_context_after_approval requires a title."
            return
        }

        guard !proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.statusMessage = "save_context_after_approval requires a summary."
            return
        }

        await runBusy("Pushing approved context into Supabase...") { [self] in
            let response = try await self.memoryClient().saveContextAfterApproval(
                projectID: projectID,
                title: proposal.title,
                summary: proposal.summary,
                decisions: proposal.decisions,
                openTasks: proposal.openTasks,
                filesDiscussed: proposal.filesDiscussed,
                nextSteps: proposal.nextSteps,
                tags: proposal.tags,
                importance: proposal.importance
            )

            let result = VirtualMCPSaveContextResult(
                saved: response.saved,
                projectID: response.project_id,
                memoryItemID: response.memory_item_id,
                sessionSummaryID: response.session_summary_id,
                toolEventID: response.tool_event?.id,
                toolName: response.tool_name,
                message: "save_context_after_approval pushed approved context into Supabase."
            )
            self.lastVirtualMCPResult = result
            self.statusMessage = result.message
        }
    }

    func importSessionAfterApproval(
        title: String,
        content: String,
        source: String,
        tagsText: String,
        importance: Int
    ) async {
        guard let selectedProject = self.selectedProject else {
            self.statusMessage = "Create or select a project before importing session context."
            return
        }

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.statusMessage = "Session import requires a title."
            return
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.statusMessage = "Paste session context before approving import."
            return
        }

        await runBusy("Importing approved session context into Supabase...") { [self] in
            let response = try await self.memoryClient().importSessionAfterApproval(
                projectID: selectedProject.id,
                title: title,
                content: content,
                source: source,
                tags: self.parseCommaSeparatedList(tagsText),
                importance: importance
            )

            let result = SessionContextImportResult(
                saved: response.saved,
                projectID: response.project_id,
                memoryItemID: response.memory_item_id,
                sessionSummaryID: response.session_summary_id,
                toolEventID: response.tool_event?.id,
                toolName: response.tool_name,
                message: "Imported approved session context into Supabase."
            )
            self.lastSessionImportResult = result
            self.statusMessage = result.message
        }
    }

    func formattedContextForChatGPT(searchQuery: String) -> String {
        let projectName = selectedProject?.name ?? "Unknown project"
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = trimmedQuery.isEmpty ? "No search query provided" : trimmedQuery

        guard !searchResults.isEmpty else {
            return """
            I searched my saved project memory for: \(queryText)

            No saved memory results were found.
            """
        }

        let formattedItems = searchResults.prefix(8).enumerated().map { index, item in
            let tags = item.tags.isEmpty ? "none" : item.tags.joined(separator: ", ")
            return """
            \(index + 1). \(item.title)
            Content: \(item.content)
            Tags: \(tags)
            """
        }.joined(separator: "\n\n")

        return """
        Use the following saved project memory as background context for this conversation. Treat it as user provided context from previous work. Use it when relevant, but do not assume it overrides my current instructions.

        Project: \(projectName)
        Memory search query: \(queryText)

        Saved memory results:
        \(formattedItems)

        Please continue from this context and ask if anything is unclear.
        """
    }

    private func loadProjects(autoCreateDefault: Bool) async throws {
        var loaded = try await self.memoryClient().listProjects()

        if loaded.isEmpty && autoCreateDefault {
            let project = try await self.memoryClient().createProject(
                name: defaultProjectName,
                description: defaultProjectDescription
            )
            loaded = [project]
            self.projects = loaded
            self.selectedProject = project
            self.statusMessage = "Created and selected default memory project."
            return
        }

        self.projects = loaded

        if let selectedProject,
           loaded.contains(where: { $0.id == selectedProject.id }) {
            self.statusMessage = "Loaded \(loaded.count) memory project(s)."
            return
        }

        self.selectedProject = loaded.first

        if let selectedProject = self.selectedProject {
            self.statusMessage = "Selected memory project: \(selectedProject.name)."
        } else {
            self.statusMessage = "No memory projects yet."
        }
    }

    private func authClient() throws -> SupabaseAuthClient {
        guard let config = self.configStore.config else {
            throw SupabaseConfigError.noConfig
        }
        return SupabaseAuthClient(projectURL: config.projectURL, publishableKey: config.publishableKey)
    }

    private func memoryClient() throws -> SupabaseMemoryClient {
        guard let config = self.configStore.config else {
            throw SupabaseConfigError.noConfig
        }
        return SupabaseMemoryClient(
            functionURL: config.memoryFunctionURL,
            publishableKey: config.publishableKey,
            bearerTokenProvider: { [weak self] in
                guard let self else { throw SupabaseAuthClientError.noSession }
                return try await self.validAccessToken()
            }
        )
    }

    private func applySignedInSession(_ session: SupabaseSession, message: String) {
        self.tokenStore.save(session)
        self.isAuthenticated = true
        self.authEmail = session.email
        self.statusMessage = message
    }

    private func validAccessToken() async throws -> String {
        guard var session = self.tokenStore.load() else {
            throw SupabaseAuthClientError.noSession
        }

        if session.expiresAt > Date().addingTimeInterval(60) {
            return session.accessToken
        }

        let refreshed = try await self.authClient().refreshSession(refreshToken: session.refreshToken)
        session = refreshed
        self.tokenStore.save(session)
        return refreshed.accessToken
    }

    private func parseLineSeparatedList(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isNewline })
            .map { line in
                line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•*"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func parseCommaSeparatedList(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func runBusy(_ message: String, operation: @escaping () async throws -> Void) async {
        self.isBusy = true
        self.statusMessage = message
        defer { self.isBusy = false }

        do {
            try await operation()
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }
}
