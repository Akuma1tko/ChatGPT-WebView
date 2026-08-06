import SwiftUI
import UIKit

struct AIChatTabView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var providerManager: AIProviderManager
    @EnvironmentObject private var profileManager: ChatGPTProfileManager
    @EnvironmentObject private var sessionPool: ChatGPTProfileSessionPool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSavingContext = false
    @State private var isPastingContext = false
    @State private var isAttachingFiles = false
    @State private var isHardRefreshing = false
    @State private var isKeyboardVisible = false
    @State private var isShowingSaveContextOptions = false
    @State private var isShowingMemoryRevisionPicker = false
    @State private var isShowingNewMemoryNameEditor = false
    @State private var pendingNewMemoryExport: ChatConversationExportResult?
    @State private var pendingNewMemoryName = ""
    @State private var detectedNewMemoryName = ""
    @State private var pendingPasteContextText: String?
    @State private var pendingAttachFileURLs: [URL] = []
    @State private var pendingPasteContextID = UUID()
    @State private var sourceMemoryIDs: [UUID] = []
    @State private var sourceMemorySessionID: String?
    @State private var lastProviderID = AIProviderID.chatGPT
    @State private var lastProfileID = ChatGPTProfile.primaryID

    var body: some View {
        ZStack(alignment: .top) {
            SecureChatGPTWebView(store: webViewStore)
                .id(activeSessionID)
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if !isKeyboardVisible {
                HStack(spacing: 4) {
                    Button {
                        if let pendingPasteContextText {
                            pastePendingContext(pendingPasteContextText)
                        } else if !pendingAttachFileURLs.isEmpty {
                            attachPendingFiles(pendingAttachFileURLs)
                        } else {
                            presentSaveContextChoices()
                        }
                    } label: {
                        Text(contextButtonTitle)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isSavingContext || isPastingContext || isAttachingFiles)

                    Menu {
                        Button {
                            hardRefreshCurrentSession()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isHardRefreshing)

                        Button {
                            webViewStore.stopCurrentActivity()
                            appModel.statusMessage = "Stopped current \(provider.displayName) activity."
                        } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }

                        Button {
                            webViewStore.scrollCurrentConversationToBottom()
                            appModel.statusMessage = "Scrolled \(provider.displayName) to the bottom."
                        } label: {
                            Label("Scroll to Bottom", systemImage: "arrow.down.to.line")
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHardRefreshing ? .red : .primary)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .accessibilityLabel("Page controls")
                    .accessibilityHint("Opens refresh, stop, and scroll to bottom actions")
                }
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
                .shadow(radius: 2)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            lastProviderID = provider.id
            lastProfileID = activeProfile.id
            handleActiveSessionAppearance()
            handlePendingMemoryStart()
        }
        .onChange(of: activeSessionID) { _ in
            let previousProviderID = lastProviderID
            let previousProfileID = lastProfileID
            lastProviderID = provider.id
            lastProfileID = activeProfile.id
            handleSessionChange(
                fromProviderID: previousProviderID,
                previousProfileID: previousProfileID
            )
        }
        .onChange(of: appModel.openChatGPTTabRequestID) { _ in
            handlePendingMemoryStart()
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .inactive || newPhase == .background else { return }
            persistAllLiveProfileSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            setTypingPriority(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            setTypingPriority(false)
        }
        .confirmationDialog(
            "Save Context",
            isPresented: $isShowingSaveContextOptions,
            titleVisibility: .visible
        ) {
            ForEach(sourceMemoryEntries) { entry in
                Button("Add Revision to \"\(entry.title)\"") {
                    saveCurrentChatAsRevision(to: entry)
                }
            }

            if !appModel.localMemoryEntries.isEmpty {
                Button("Choose Existing Memory") {
                    isShowingMemoryRevisionPicker = true
                }
            }

            Button("Save as New Memory") {
                prepareNewMemorySave()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add this full chat as a new revision of an existing Memory, or create a new Memory.")
        }
        .sheet(isPresented: $isShowingMemoryRevisionPicker) {
            MemoryRevisionDestinationPicker(entries: appModel.localMemoryEntries) { entry in
                isShowingMemoryRevisionPicker = false
                saveCurrentChatAsRevision(to: entry)
            }
        }
        .sheet(isPresented: $isShowingNewMemoryNameEditor) {
            NewMemoryNameEditor(
                detectedChatName: detectedNewMemoryName,
                memoryName: $pendingNewMemoryName,
                onSave: savePendingNewMemory,
                onCancel: cancelPendingNewMemorySave
            )
        }
    }

    private var provider: AIProvider {
        providerManager.activeProvider
    }

    private var activeProfile: ChatGPTProfile {
        profileManager.activeProfile(for: provider.id)
    }

    private var activeSessionID: String {
        "\(provider.id.rawValue)::\(activeProfile.id)"
    }

    private var webViewStore: ChatGPTWebViewStore {
        let providerID = provider.id
        return sessionPool.store(
            for: provider,
            profile: activeProfile,
            onDetectedDisplayName: { profileID, displayName in
                profileManager.updateDetectedDisplayName(
                    displayName,
                    for: profileID,
                    providerID: providerID
                )
            }
        )
    }

    private var sourceMemoryEntries: [LocalMemoryEntry] {
        guard sourceMemorySessionID == activeSessionID else { return [] }
        return sourceMemoryIDs.compactMap { id in
            appModel.localMemoryEntries.first(where: { $0.id == id })
        }
    }

    private var contextButtonTitle: String {
        if isPastingContext { return "Pasting" }
        if isAttachingFiles { return "Attaching" }
        if pendingPasteContextText != nil { return "Paste Context" }
        if !pendingAttachFileURLs.isEmpty { return "Attach Files" }
        return isSavingContext ? "Saving" : "Save Context"
    }

    private func setTypingPriority(_ isTyping: Bool) {
        isKeyboardVisible = isTyping
        sessionPool.setTypingPriority(
            isTyping,
            providerID: provider.id,
            profileID: activeProfile.id
        )
    }

    private func handleActiveSessionAppearance() {
        guard activeProfile.kind == .guest else { return }
        Task { @MainActor in
            await sessionPool.resetGuest(
                provider: provider,
                profile: activeProfile,
                onDetectedDisplayName: { _, _ in }
            )
        }
    }

    private func handleSessionChange(
        fromProviderID previousProviderID: AIProviderID,
        previousProfileID: String
    ) {
        let activeProvider = provider
        let newActiveProfile = activeProfile
        isKeyboardVisible = false
        isHardRefreshing = false

        sessionPool.setTypingPriority(
            false,
            providerID: previousProviderID,
            profileID: previousProfileID
        )
        sessionPool.setTypingPriority(
            false,
            providerID: activeProvider.id,
            profileID: newActiveProfile.id
        )

        Task { @MainActor in
            await sessionPool.persistSession(
                providerID: previousProviderID,
                profileID: previousProfileID
            )

            if newActiveProfile.kind == .guest {
                await sessionPool.resetGuest(
                    provider: activeProvider,
                    profile: newActiveProfile,
                    onDetectedDisplayName: { _, _ in }
                )
            }
        }
    }

    private func persistAllLiveProfileSessions() {
        Task { @MainActor in
            await sessionPool.persistAllSessions()
        }
    }

    private func handlePendingMemoryStart() {
        guard let payload = PendingLocalMemoryAttachment.consumePayload() else {
            return
        }

        sourceMemoryIDs = payload.sourceMemoryIDs
        sourceMemorySessionID = activeSessionID

        switch payload.handoffMode {
        case .newConversation:
            webViewStore.startNewChatWithPendingUploadURLs(payload.fileURLs)
        case .currentConversation:
            webViewStore.preparePendingUploadURLs(payload.fileURLs)
        }

        let destination = payload.handoffMode == .currentConversation
            ? "the current \(provider.displayName) conversation"
            : provider.displayName

        if let composerText = payload.composerText, !composerText.isEmpty {
            pendingPasteContextText = composerText
            pendingAttachFileURLs = payload.fileURLs
            pendingPasteContextID = UUID()
            if payload.fileURLs.isEmpty {
                appModel.statusMessage = "Saved Markdown is ready for \(destination). Tap Paste Context to insert it, or continue without it."
            } else {
                appModel.statusMessage = "Saved Markdown and \(payload.fileURLs.count) Memory attachment\(payload.fileURLs.count == 1 ? "" : "s") are ready for \(destination). Tap Paste Context first, then Attach Files."
            }
            watchForConversationStartWithoutPaste(pendingPasteContextID)
        } else if !payload.fileURLs.isEmpty {
            pendingAttachFileURLs = payload.fileURLs
            pendingPasteContextText = nil
            appModel.statusMessage = "Files are ready. Tap Attach Files to attach from app Memory to \(destination)."
        }
    }

    private func pastePendingContext(_ text: String) {
        guard !isPastingContext else { return }
        isPastingContext = true

        Task { @MainActor in
            defer { isPastingContext = false }
            let inserted = await webViewStore.injectComposerText(text)
            if inserted {
                pendingPasteContextText = nil
                pendingPasteContextID = UUID()
                if pendingAttachFileURLs.isEmpty {
                    appModel.statusMessage = "Pasted saved context into \(provider.displayName). Review and send."
                } else {
                    appModel.statusMessage = "Pasted saved context into \(provider.displayName). Tap Attach Files to add the remaining Memory attachment\(pendingAttachFileURLs.count == 1 ? "" : "s")."
                }
            } else {
                appModel.statusMessage = "Could not paste yet. Wait for \(provider.displayName) to finish loading, then tap Paste Context again."
            }
        }
    }

    private func attachPendingFiles(_ urls: [URL]) {
        guard !isAttachingFiles, !urls.isEmpty else { return }

        // Attach Files is a one-pass temporary action. Clear its UI state immediately
        // when pressed so the primary control returns to Save Context regardless of
        // provider-specific upload acknowledgement behavior.
        isAttachingFiles = true
        pendingAttachFileURLs = []
        webViewStore.preparePendingUploadURLs(urls)
        isAttachingFiles = false
        appModel.statusMessage = "Attachment handoff started for \(provider.displayName). Save Context is available again."

        Task { @MainActor in
            let handoff = await webViewStore.injectFilesIntoChatGPTUpload(urls)
            webViewStore.preparePendingUploadURLs([])

            if handoff.unsupportedURLs.isEmpty && handoff.failedURLs.isEmpty {
                appModel.statusMessage = "Context bundle handoff completed for \(provider.displayName). Review the attached context before sending."
            } else {
                let attemptedCount = urls.count
                appModel.statusMessage = "Attempted \(attemptedCount) Memory attachment\(attemptedCount == 1 ? "" : "s") for \(provider.displayName). Save Context is available."
            }
        }
    }

    private func hardRefreshCurrentSession() {
        guard !isHardRefreshing else { return }
        isHardRefreshing = true
        appModel.statusMessage = "Hard refreshing \(provider.displayName)..."

        Task { @MainActor in
            await webViewStore.hardRefreshCurrentSession()
            isHardRefreshing = false
            appModel.statusMessage = "Hard refresh completed for \(provider.displayName)."
        }
    }

    private func watchForConversationStartWithoutPaste(_ id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let baselineUserMessages = await webViewStore.userMessageCount()

            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard pendingPasteContextID == id, pendingPasteContextText != nil else { return }
                guard !isKeyboardVisible else { continue }

                let currentUserMessages = await webViewStore.userMessageCount()
                if currentUserMessages > baselineUserMessages {
                    pendingPasteContextText = nil
                    pendingPasteContextID = UUID()
                    if pendingAttachFileURLs.isEmpty {
                        appModel.statusMessage = "Continuing without pasted Memory context. Save Context is available again."
                    } else {
                        appModel.statusMessage = "Continuing without pasted Memory text. Tap Attach Files to add the remaining Memory attachment\(pendingAttachFileURLs.count == 1 ? "" : "s")."
                    }
                    return
                }
            }
        }
    }

    private func presentSaveContextChoices() {
        guard !isSavingContext else { return }
        appModel.reloadLocalMemory()
        isShowingSaveContextOptions = true
    }

    private func prepareNewMemorySave() {
        guard !isSavingContext else { return }
        isSavingContext = true
        appModel.statusMessage = "Reading \(provider.displayName) chat before naming the new Memory..."

        Task { @MainActor in
            defer { isSavingContext = false }
            do {
                let export = try await webViewStore.exportCurrentConversation()
                let chatName = export.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackName = "\(provider.displayName) Conversation"

                pendingNewMemoryExport = export
                detectedNewMemoryName = chatName.isEmpty ? fallbackName : chatName
                pendingNewMemoryName = detectedNewMemoryName
                isShowingNewMemoryNameEditor = true
                appModel.statusMessage = "Choose a name for the new Memory. The existing chat name is prefilled."
            } catch {
                clearPendingNewMemorySave()
                appModel.statusMessage = "Save Context failed: \(error.localizedDescription)"
            }
        }
    }

    private func savePendingNewMemory(_ requestedName: String) {
        guard !isSavingContext, let export = pendingNewMemoryExport else { return }

        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedName = detectedNewMemoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty
            ? (detectedName.isEmpty ? "\(provider.displayName) Conversation" : detectedName)
            : trimmedName

        isShowingNewMemoryNameEditor = false
        isSavingContext = true
        appModel.statusMessage = "Saving \"\(finalName)\" as a new Memory..."

        Task { @MainActor in
            defer { isSavingContext = false }
            do {
                let result = try LocalMemoryStore().saveExportedConversation(
                    projectName: appModel.selectedProject?.name ?? "ContextPort",
                    title: finalName,
                    markdownText: export.markdown,
                    pdfData: export.pdfData,
                    sourceURL: export.sourceURL,
                    messageCount: export.messageCount,
                    exportedAt: export.exportedAt
                )

                clearPendingNewMemorySave()
                finishMemorySave(result)
            } catch {
                isShowingNewMemoryNameEditor = true
                appModel.statusMessage = "Save Context failed: \(error.localizedDescription)"
            }
        }
    }

    private func cancelPendingNewMemorySave() {
        isShowingNewMemoryNameEditor = false
        clearPendingNewMemorySave()
        appModel.statusMessage = "New Memory save cancelled."
    }

    private func clearPendingNewMemorySave() {
        pendingNewMemoryExport = nil
        pendingNewMemoryName = ""
        detectedNewMemoryName = ""
    }

    private func saveCurrentChatAsRevision(to memory: LocalMemoryEntry) {
        guard !isSavingContext else { return }
        isSavingContext = true
        appModel.statusMessage = "Adding a new revision to \"\(memory.title)\"..."

        Task { @MainActor in
            defer { isSavingContext = false }
            do {
                let export = try await webViewStore.exportCurrentConversation()
                let result = try LocalMemoryStore().addRevision(
                    to: memory,
                    markdownText: export.markdown,
                    pdfData: export.pdfData,
                    sourceURL: export.sourceURL,
                    messageCount: export.messageCount,
                    exportedAt: export.exportedAt
                )
                finishMemorySave(result)
            } catch {
                appModel.statusMessage = "Save Context failed: \(error.localizedDescription)"
            }
        }
    }

    private func finishMemorySave(_ result: LocalMemorySaveResult) {
        sourceMemoryIDs = [result.entry.id]
        sourceMemorySessionID = activeSessionID
        appModel.reloadLocalMemory()
        appModel.statusMessage = result.message
    }
}

typealias ChatGPTTabView = AIChatTabView


private struct NewMemoryNameEditor: View {
    @Environment(\.dismiss) private var dismiss

    let detectedChatName: String
    @Binding var memoryName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    private var trimmedName: String {
        memoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Memory Name") {
                    TextField("Memory name", text: $memoryName)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)

                    Button("Use Chat Name") {
                        memoryName = detectedChatName
                    }
                    .disabled(memoryName == detectedChatName)
                }

                Section("Existing Chat Name") {
                    Text(detectedChatName)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Name New Memory")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save Memory") {
                        let name = trimmedName
                        dismiss()
                        onSave(name)
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}

private struct MemoryRevisionDestinationPicker: View {
    @Environment(\.dismiss) private var dismiss

    let entries: [LocalMemoryEntry]
    let onSelect: (LocalMemoryEntry) -> Void

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.isFavorite ? "star.fill" : "externaldrive.connected.to.line.below")
                            .foregroundColor(entry.isFavorite ? .yellow : .secondary)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            Text(revisionLabel(for: entry))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func revisionLabel(for entry: LocalMemoryEntry) -> String {
        let noun = entry.revisionCount == 1 ? "revision" : "revisions"
        return "\(entry.revisionCount) \(noun)"
    }
}
