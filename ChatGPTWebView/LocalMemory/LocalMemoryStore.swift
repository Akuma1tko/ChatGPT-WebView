import Foundation

enum LocalMemoryStoreError: LocalizedError {
    case emptyMarkdown
    case missingPDF
    case missingMarkdown
    case memoryNotFound

    var errorDescription: String? {
        switch self {
        case .emptyMarkdown:
            return "The exported AI conversation did not contain readable Markdown."
        case .missingPDF:
            return "No saved PDF file was found for this memory entry."
        case .missingMarkdown:
            return "No saved Markdown file was found for this memory entry."
        case .memoryNotFound:
            return "The selected Memory could not be found."
        }
    }
}

final class LocalMemoryStore {
    private let fm: FileManager
    private let root: URL
    private let pdfs: URL
    private let markdown: URL
    private let visibleRoot: URL
    private let visiblePDFs: URL
    private let visibleMarkdown: URL
    private let index: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fm = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        self.root = support.appendingPathComponent("LocalMemoryVault", isDirectory: true)
        self.pdfs = root.appendingPathComponent("PDFs", isDirectory: true)
        self.markdown = root.appendingPathComponent("Markdown", isDirectory: true)
        self.index = root.appendingPathComponent("entries.json")

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        self.visibleRoot = documents.appendingPathComponent("ChatGPT Memory", isDirectory: true)
        self.visiblePDFs = visibleRoot.appendingPathComponent("PDFs", isDirectory: true)
        self.visibleMarkdown = visibleRoot.appendingPathComponent("Markdown", isDirectory: true)

        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder; self.decoder = decoder
    }

    func loadEntries() throws -> [LocalMemoryEntry] {
        try ensureInternalFolders()
        guard fm.fileExists(atPath: index.path) else { return [] }
        let data = try Data(contentsOf: index)
        guard !data.isEmpty else { return [] }
        return try decoder.decode([LocalMemoryEntry].self, from: data).sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func saveExportedConversation(
        projectName: String,
        title: String,
        markdownText: String,
        pdfData: Data,
        sourceURL: String?,
        messageCount: Int,
        exportedAt: String
    ) throws -> LocalMemorySaveResult {
        let body = markdownText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw LocalMemoryStoreError.emptyMarkdown }

        var entries = try loadEntries()
        let id = UUID()
        let revisionID = UUID()
        let now = Date()
        let pdfName = "\(revisionID.uuidString).pdf"
        let mdName = "\(revisionID.uuidString).md"
        let source = clean(sourceURL ?? "ai_web", "ai_web")
        let revision = LocalMemoryRevision(
            id: revisionID,
            number: 1,
            createdAt: now,
            source: source,
            pdfFilename: pdfName,
            markdownFilename: mdName,
            messageCount: messageCount,
            exportedAt: exportedAt
        )
        let entry = LocalMemoryEntry(
            id: id,
            projectName: clean(projectName, "ContextPort"),
            title: clean(title, "Exported chat"),
            content: body,
            source: source,
            tags: ["chat-export", "context", "local", "markdown", "memory"],
            importance: 5,
            createdAt: now,
            updatedAt: now,
            pdfFilename: pdfName,
            markdownFilename: mdName,
            messageCount: messageCount,
            exportedAt: exportedAt,
            attachmentFilenames: [pdfName, mdName],
            revisions: [revision]
        )

        try ensureInternalFolders()
        try pdfData.write(to: pdfs.appendingPathComponent(pdfName), options: [.atomic])
        try body.write(to: markdown.appendingPathComponent(mdName), atomically: true, encoding: .utf8)
        entries.append(entry)
        try write(entries)
        return LocalMemorySaveResult(
            entry: entry,
            totalCount: entries.count,
            message: "Saved full chat to Memory as Revision 1."
        )
    }

    @discardableResult
    func addRevision(
        to memory: LocalMemoryEntry,
        markdownText: String,
        pdfData: Data,
        sourceURL: String?,
        messageCount: Int,
        exportedAt: String
    ) throws -> LocalMemorySaveResult {
        let body = markdownText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw LocalMemoryStoreError.emptyMarkdown }

        var entries = try loadEntries()
        guard let entryIndex = entries.firstIndex(where: { $0.id == memory.id }) else {
            throw LocalMemoryStoreError.memoryNotFound
        }

        var entry = entries[entryIndex]
        let nextNumber = (entry.revisions.map(\.number).max() ?? 0) + 1
        let revisionID = UUID()
        let now = Date()
        let source = clean(sourceURL ?? "ai_web", "ai_web")
        let pdfName = "\(revisionID.uuidString).pdf"
        let mdName = "\(revisionID.uuidString).md"
        let revision = LocalMemoryRevision(
            id: revisionID,
            number: nextNumber,
            createdAt: now,
            source: source,
            pdfFilename: pdfName,
            markdownFilename: mdName,
            messageCount: messageCount,
            exportedAt: exportedAt
        )

        try ensureInternalFolders()
        try pdfData.write(to: pdfs.appendingPathComponent(pdfName), options: [.atomic])
        try body.write(to: markdown.appendingPathComponent(mdName), atomically: true, encoding: .utf8)

        entry.content = body
        entry.source = source
        entry.updatedAt = now
        entry.pdfFilename = pdfName
        entry.markdownFilename = mdName
        entry.messageCount = messageCount
        entry.exportedAt = exportedAt
        entry.attachmentFilenames = Array(Set(entry.attachmentFilenames + [pdfName, mdName])).sorted()
        entry.revisions.append(revision)
        entry.revisions.sort { $0.number < $1.number }
        entries[entryIndex] = entry
        try write(entries)

        return LocalMemorySaveResult(
            entry: entry,
            totalCount: entries.count,
            message: "Added Revision \(nextNumber) to \"\(entry.title)\"."
        )
    }

    @discardableResult
    func saveExportedPDF(projectName: String, title: String, pdfData: Data, sourceURL: String?) throws -> LocalMemorySaveResult {
        try saveExportedConversation(
            projectName: projectName,
            title: title,
            markdownText: "# \(title)\n\nPDF only export.",
            pdfData: pdfData,
            sourceURL: sourceURL,
            messageCount: 0,
            exportedAt: Self.iso.string(from: Date())
        )
    }

    @discardableResult
    func saveEntry(projectName: String, title: String, content: String, source: String, tags: [String], importance: Int) throws -> LocalMemorySaveResult {
        var entries = try loadEntries()
        let id = UUID()
        let revisionID = UUID()
        let now = Date()
        let pdfName = "\(revisionID.uuidString).pdf"
        let mdName = "\(revisionID.uuidString).md"
        let cleanSource = clean(source, "manual")
        let revision = LocalMemoryRevision(
            id: revisionID,
            number: 1,
            createdAt: now,
            source: cleanSource,
            pdfFilename: pdfName,
            markdownFilename: mdName,
            exportedAt: Self.iso.string(from: now)
        )
        var entry = LocalMemoryEntry(
            id: id,
            projectName: clean(projectName, "Local Project"),
            title: clean(title, "Untitled memory"),
            content: clean(content, ""),
            source: cleanSource,
            tags: Array(Set(tags + ["local", "memory"])).sorted(),
            importance: importance,
            createdAt: now,
            updatedAt: now,
            pdfFilename: pdfName,
            markdownFilename: mdName,
            exportedAt: Self.iso.string(from: now),
            attachmentFilenames: [pdfName, mdName],
            revisions: [revision]
        )
        try ensureInternalFolders()
        try LocalMemoryPDFRenderer.render(entry: entry, to: pdfs.appendingPathComponent(pdfName))
        try entry.content.write(to: markdown.appendingPathComponent(mdName), atomically: true, encoding: .utf8)
        entry.pdfFilename = pdfName
        entry.markdownFilename = mdName
        entries.append(entry)
        try write(entries)
        return LocalMemorySaveResult(entry: entry, totalCount: entries.count, message: "Saved context to Memory as Revision 1.")
    }

    func search(_ query: String, limit: Int = 25) throws -> [LocalMemoryEntry] { Array(try loadEntries().prefix(limit)) }
    func renderProjectContext(projectName: String, limit: Int = 20) throws -> String { try loadEntries().prefix(limit).map { $0.title }.joined(separator: "\n") }

    func pdfURL(for entry: LocalMemoryEntry) -> URL? { url(entry.pdfFilename, in: pdfs) }
    func markdownURL(for entry: LocalMemoryEntry) -> URL? { url(entry.markdownFilename, in: markdown) }
    func pdfURL(for revision: LocalMemoryRevision) -> URL? { url(revision.pdfFilename, in: pdfs) }
    func markdownURL(for revision: LocalMemoryRevision) -> URL? { url(revision.markdownFilename, in: markdown) }
    func visiblePDFURL(for entry: LocalMemoryEntry) -> URL? { url(visiblePDFName(for: entry), in: visiblePDFs) }
    func visibleMarkdownURL(for entry: LocalMemoryEntry) -> URL? { url(visibleMarkdownName(for: entry), in: visibleMarkdown) }

    func markdownText(for entry: LocalMemoryEntry) -> String? {
        if let latest = entry.latestRevision,
           let text = markdownText(for: latest, in: entry) {
            return text
        }
        return markdownURL(for: entry).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? (entry.content.isEmpty ? nil : entry.content)
    }

    func markdownText(for revision: LocalMemoryRevision, in entry: LocalMemoryEntry) -> String? {
        if let source = markdownURL(for: revision),
           let text = try? String(contentsOf: source, encoding: .utf8) {
            return text
        }

        if revision.number == entry.latestRevision?.number, !entry.content.isEmpty {
            return entry.content
        }

        return nil
    }

    func fileURLs(for entry: LocalMemoryEntry) -> [URL] {
        [visiblePDFURL(for: entry), visibleMarkdownURL(for: entry), pdfURL(for: entry), markdownURL(for: entry)]
            .compactMap { $0 }
            .uniqueByPath()
    }

    @discardableResult
    func exportPDFToFiles(for entry: LocalMemoryEntry) throws -> URL {
        guard let source = pdfURL(for: entry) else { throw LocalMemoryStoreError.missingPDF }
        try ensureVisibleFolders()
        let destination = visiblePDFs.appendingPathComponent(visiblePDFName(for: entry))
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
        return destination
    }

    @discardableResult
    func exportMarkdownToFiles(for entry: LocalMemoryEntry) throws -> URL {
        try ensureVisibleFolders()
        let destination = visibleMarkdown.appendingPathComponent(visibleMarkdownName(for: entry))
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }

        if let source = markdownURL(for: entry) {
            try fm.copyItem(at: source, to: destination)
        } else if let text = markdownText(for: entry) {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } else {
            throw LocalMemoryStoreError.missingMarkdown
        }

        return destination
    }

    func deleteEntry(_ entry: LocalMemoryEntry) throws {
        var entries = try loadEntries()
        entries.removeAll { $0.id == entry.id }

        let revisionFiles = entry.revisions.flatMap { revision in
            [pdfURL(for: revision), markdownURL(for: revision)]
        }
        let fileURLs = revisionFiles + [
            pdfURL(for: entry),
            markdownURL(for: entry),
            visiblePDFURL(for: entry),
            visibleMarkdownURL(for: entry)
        ]
        for fileURL in fileURLs.compactMap({ $0 }).uniqueByPath() {
            try? fm.removeItem(at: fileURL)
        }
        try write(entries)
    }

    func setFavorite(_ isFavorite: Bool, for entry: LocalMemoryEntry) throws {
        var entries = try loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isFavorite = isFavorite
        try write(entries)
    }

    func toggleFavorite(for entry: LocalMemoryEntry) throws {
        try setFavorite(!entry.isFavorite, for: entry)
    }

    func startNewChatContext(for entry: LocalMemoryEntry) -> String {
        let pdfName = entry.pdfFilename ?? "none"
        let markdownName = entry.markdownFilename ?? "none"
        return [
            "Start a new chat using this saved ContextPort Memory.",
            "",
            "Title: \(entry.title)",
            "Source: \(entry.source)",
            "Revisions: \(entry.revisionCount)",
            "PDF: \(pdfName)",
            "Markdown: \(markdownName)",
            "",
            "Use the saved Memory revision history as context for this new chat."
        ].joined(separator: "\n")
    }

    private func visiblePDFName(for entry: LocalMemoryEntry) -> String {
        "\(cleanFileName(entry.title, fallback: entry.id.uuidString)).pdf"
    }

    private func visibleMarkdownName(for entry: LocalMemoryEntry) -> String {
        "\(cleanFileName(entry.title, fallback: entry.id.uuidString)).md"
    }

    private func url(_ name: String?, in folder: URL) -> URL? {
        guard let name else { return nil }
        let url = folder.appendingPathComponent(name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    private func ensureInternalFolders() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: pdfs, withIntermediateDirectories: true)
        try fm.createDirectory(at: markdown, withIntermediateDirectories: true)
    }

    private func ensureVisibleFolders() throws {
        try fm.createDirectory(at: visibleRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: visiblePDFs, withIntermediateDirectories: true)
        try fm.createDirectory(at: visibleMarkdown, withIntermediateDirectories: true)
    }

    private func write(_ entries: [LocalMemoryEntry]) throws {
        try ensureInternalFolders()
        try encoder.encode(entries.sorted { $0.updatedAt > $1.updatedAt }).write(to: index, options: [.atomic])
    }

    private func clean(_ value: String, _ fallback: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private func cleanFileName(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(80))
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private extension Array where Element == URL {
    func uniqueByPath() -> [URL] {
        var seen = Set<String>()
        return filter { seen.insert($0.path).inserted }
    }
}
