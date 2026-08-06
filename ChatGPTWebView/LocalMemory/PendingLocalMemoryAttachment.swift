import Foundation

enum MemoryHandoffMode: String {
    case newConversation = "new_conversation"
    case currentConversation = "current_conversation"
}

struct PendingLocalMemoryPayload {
    let sourceMemoryIDs: [UUID]
    let fileURLs: [URL]
    let composerText: String?
    let handoffMode: MemoryHandoffMode
}

enum PendingLocalMemoryAttachment {
    private static let entryIDsKey = "PendingLocalMemoryAttachmentEntryIDs"
    private static let entryIDKey = "PendingLocalMemoryAttachmentEntryID"
    private static let selectedFilePathsKey = "PendingLocalMemoryAttachmentSelectedFilePaths"
    private static let composerTextPathKey = "PendingLocalMemoryAttachmentComposerTextPath"
    private static let injectMarkdownKey = "PendingLocalMemoryAttachmentInjectMarkdown"
    private static let handoffModeKey = "PendingLocalMemoryAttachmentHandoffMode"

    static func mark(
        _ entries: [LocalMemoryEntry],
        fileURLs: [URL] = [],
        composerTextURL: URL? = nil,
        handoffMode: MemoryHandoffMode = .newConversation
    ) {
        let defaults = UserDefaults.standard
        defaults.set(entries.map { $0.id.uuidString }, forKey: entryIDsKey)
        defaults.set(fileURLs.map(\.path), forKey: selectedFilePathsKey)
        defaults.set(composerTextURL?.path, forKey: composerTextPathKey)
        defaults.set(composerTextURL != nil, forKey: injectMarkdownKey)
        defaults.set(handoffMode.rawValue, forKey: handoffModeKey)
    }

    static func mark(
        _ entry: LocalMemoryEntry,
        fileURLs: [URL] = [],
        composerTextURL: URL? = nil,
        handoffMode: MemoryHandoffMode = .newConversation
    ) {
        mark(
            [entry],
            fileURLs: fileURLs,
            composerTextURL: composerTextURL,
            handoffMode: handoffMode
        )
    }

    static func consumePayload() -> PendingLocalMemoryPayload? {
        let defaults = UserDefaults.standard
        var idTexts = defaults.stringArray(forKey: entryIDsKey) ?? []
        if idTexts.isEmpty, let legacyID = defaults.string(forKey: entryIDKey) {
            idTexts = [legacyID]
        }
        guard !idTexts.isEmpty else { return nil }

        let selectedPaths = defaults.stringArray(forKey: selectedFilePathsKey) ?? []
        let composerTextPath = defaults.string(forKey: composerTextPathKey)
        let shouldInjectMarkdown = defaults.bool(forKey: injectMarkdownKey)
        let handoffMode = defaults.string(forKey: handoffModeKey)
            .flatMap(MemoryHandoffMode.init(rawValue:))
            ?? .newConversation
        defaults.removeObject(forKey: entryIDsKey)
        defaults.removeObject(forKey: entryIDKey)
        defaults.removeObject(forKey: selectedFilePathsKey)
        defaults.removeObject(forKey: composerTextPathKey)
        defaults.removeObject(forKey: injectMarkdownKey)
        defaults.removeObject(forKey: handoffModeKey)

        let selectedIDs = idTexts.compactMap(UUID.init(uuidString:))
        guard let entries = try? LocalMemoryStore().loadEntries() else { return nil }
        let selectedEntries = selectedIDs.compactMap { id in entries.first(where: { $0.id == id }) }
        guard !selectedEntries.isEmpty else { return nil }

        let selectedURLs = selectedPaths.map(URL.init(fileURLWithPath:))
        let composerText: String?
        if let composerTextPath {
            composerText = try? String(contentsOfFile: composerTextPath, encoding: .utf8)
        } else if shouldInjectMarkdown {
            // Compatibility for a pending inline handoff created by ContextPort 2.6 or older.
            composerText = MemoryContextBundleBuilder.composerText(for: selectedEntries)
        } else {
            composerText = nil
        }

        return PendingLocalMemoryPayload(
            sourceMemoryIDs: selectedEntries.map(\.id),
            fileURLs: selectedURLs,
            composerText: composerText,
            handoffMode: handoffMode
        )
    }

    static func consumeFileURLs() -> [URL] {
        consumePayload()?.fileURLs ?? []
    }
}
