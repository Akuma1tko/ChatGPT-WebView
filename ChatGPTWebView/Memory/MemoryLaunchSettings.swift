import SwiftUI

enum MemorySharingFormat: String, CaseIterable, Hashable, Identifiable, Sendable {
    case askEveryTime = "ask_every_time"
    case pdfAndMarkdown = "pdf_and_markdown"
    case pdfOnly = "pdf_only"
    case markdownOnly = "markdown_only"
    case insertMarkdownText = "insert_markdown_text"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askEveryTime:
            return "Ask Every Time"
        case .pdfAndMarkdown:
            return "PDF + Markdown"
        case .pdfOnly:
            return "PDF Only"
        case .markdownOnly:
            return "Markdown Only"
        case .insertMarkdownText:
            return "Insert Markdown Text"
        }
    }

    var includesPDF: Bool {
        self == .pdfAndMarkdown || self == .pdfOnly
    }

    var includesMarkdownFile: Bool {
        self == .pdfAndMarkdown || self == .markdownOnly
    }

    var injectsMarkdownText: Bool {
        self == .insertMarkdownText
    }

    static var launchFormats: [MemorySharingFormat] {
        allCases.filter { $0 != .askEveryTime }
    }
}

@MainActor
final class MemoryLaunchSettings: ObservableObject {
    @Published var sharingFormat: MemorySharingFormat {
        didSet {
            UserDefaults.standard.set(sharingFormat.rawValue, forKey: Self.sharingFormatKey)
        }
    }

    private static let sharingFormatKey = "MemorySharingFormat"

    init() {
        let storedValue = UserDefaults.standard.string(forKey: Self.sharingFormatKey)
        self.sharingFormat = storedValue.flatMap(MemorySharingFormat.init(rawValue:)) ?? .askEveryTime
    }
}

struct MemoryLaunchRequest: Identifiable {
    let id = UUID()
    let entries: [LocalMemoryEntry]
}

struct MemoryLaunchSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var providerManager: AIProviderManager
    @EnvironmentObject private var launchSettings: MemoryLaunchSettings
    @Environment(\.dismiss) private var dismiss

    let entries: [LocalMemoryEntry]
    var onLaunched: () -> Void = {}

    @State private var pendingProvider: AIProvider?
    @State private var isCurrentConversationDestination = false
    @State private var showFormatSelection = false
    @State private var isPreparing = false
    @State private var launchError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Share With") {
                    ForEach(providerManager.providers) { provider in
                        Button {
                            chooseProvider(provider)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: provider.systemImage)
                                    .frame(width: 24)
                                Text(provider.displayName)
                                Spacer()
                                if isPreparing, pendingProvider?.id == provider.id {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparing)
                    }

                    Button {
                        chooseCurrentConversation()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "paperclip")
                                .frame(width: 24)
                            Text("Current Conversation")
                            Spacer()
                            if isPreparing, isCurrentConversationDestination {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparing)
                    .accessibilityHint("Attach the selected Memory to the current AI conversation without starting a new chat")
                }

                Section {
                    Text("\(entries.count) \(entries.count == 1 ? "memory" : "memories") selected")
                        .foregroundColor(.secondary)
                }

                if let launchError {
                    Section {
                        Text(launchError)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Share Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isPreparing)
                }
            }
            .confirmationDialog(
                "Context Format",
                isPresented: $showFormatSelection,
                titleVisibility: .visible
            ) {
                ForEach(MemorySharingFormat.launchFormats) { format in
                    Button(format.displayName) {
                        if isCurrentConversationDestination {
                            attachToCurrentConversation(format: format)
                        } else if let provider = pendingProvider {
                            launch(provider: provider, format: format)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingProvider = nil
                    isCurrentConversationDestination = false
                }
            } message: {
                Text("Selected memories are first combined into one ContextPort context bundle. PDF and Markdown are two formats of the same combined context. Saved Memory attachments travel with the launch as separate files.")
            }
        }
    }

    private func chooseProvider(_ provider: AIProvider) {
        launchError = nil
        pendingProvider = provider
        isCurrentConversationDestination = false
        if launchSettings.sharingFormat == .askEveryTime {
            showFormatSelection = true
        } else {
            launch(provider: provider, format: launchSettings.sharingFormat)
        }
    }

    private func chooseCurrentConversation() {
        launchError = nil
        pendingProvider = nil
        isCurrentConversationDestination = true
        if launchSettings.sharingFormat == .askEveryTime {
            showFormatSelection = true
        } else {
            attachToCurrentConversation(format: launchSettings.sharingFormat)
        }
    }

    private func launch(provider: AIProvider, format: MemorySharingFormat) {
        prepareHandoff(
            provider: provider,
            format: format,
            handoffMode: .newConversation
        )
    }

    private func attachToCurrentConversation(format: MemorySharingFormat) {
        prepareHandoff(
            provider: providerManager.activeProvider,
            format: format,
            handoffMode: .currentConversation
        )
    }

    private func prepareHandoff(
        provider: AIProvider,
        format: MemorySharingFormat,
        handoffMode: MemoryHandoffMode
    ) {
        guard !isPreparing else { return }
        isPreparing = true
        launchError = nil

        let isCurrentConversation = handoffMode == .currentConversation
        isCurrentConversationDestination = isCurrentConversation
        pendingProvider = isCurrentConversation ? nil : provider

        let destination = isCurrentConversation
            ? "the current \(provider.displayName) conversation"
            : provider.displayName
        appModel.statusMessage = "Preparing \(entries.count) Memory \(entries.count == 1 ? "entry" : "entries") for \(destination)..."

        let selectedEntries = entries
        Task { @MainActor in
            defer { isPreparing = false }
            do {
                let bundle = try await Task.detached(priority: .userInitiated) {
                    try MemoryContextBundleBuilder().build(entries: selectedEntries, format: format)
                }.value

                let supplementalAttachmentURLs = selectedEntries.compactMap {
                    DeveloperSourceMemoryArchiveBuilder.existingArchiveURL(for: $0)
                }
                var seenPaths = Set<String>()
                let handoffFileURLs = (bundle.fileURLs + supplementalAttachmentURLs).filter { url in
                    seenPaths.insert(url.standardizedFileURL.path).inserted
                }

                PendingLocalMemoryAttachment.mark(
                    selectedEntries,
                    fileURLs: handoffFileURLs,
                    composerTextURL: bundle.composerTextURL,
                    handoffMode: handoffMode
                )

                if handoffMode == .newConversation {
                    providerManager.selectProvider(provider)
                }

                appModel.statusMessage = launchStatusMessage(
                    bundle: bundle,
                    handoffFileURLs: handoffFileURLs,
                    supplementalAttachmentCount: supplementalAttachmentURLs.count,
                    providerName: provider.displayName,
                    isCurrentConversation: isCurrentConversation
                )
                appModel.openChatGPTTabRequestID = UUID()
                onLaunched()
                dismiss()
            } catch {
                launchError = "Could not prepare Memory context: \(error.localizedDescription)"
                appModel.statusMessage = launchError ?? "Could not prepare Memory context."
            }
        }
    }

    private func launchStatusMessage(
        bundle: MemoryContextBundle,
        handoffFileURLs: [URL],
        supplementalAttachmentCount: Int,
        providerName: String,
        isCurrentConversation: Bool
    ) -> String {
        let destination = isCurrentConversation
            ? "the current \(providerName) conversation"
            : providerName

        if bundle.format.injectsMarkdownText {
            if supplementalAttachmentCount > 0 {
                return "Memory context and \(supplementalAttachmentCount) saved attachment\(supplementalAttachmentCount == 1 ? "" : "s") are ready for \(destination). Tap Paste Context, then Attach Files."
            }
            if isCurrentConversation {
                return "Memory context is ready for \(destination). Tap Paste Context to insert it, or continue without it."
            }
            return bundle.statusMessage(for: providerName)
        }

        let names = handoffFileURLs.map(\.lastPathComponent).joined(separator: ", ")
        return "\(bundle.selectedCount) Memory \(bundle.selectedCount == 1 ? "entry is" : "entries are") ready for \(destination): \(names)."
    }
}
