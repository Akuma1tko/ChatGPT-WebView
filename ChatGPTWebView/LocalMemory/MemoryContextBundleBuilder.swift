import Foundation

enum MemoryContextBundleError: LocalizedError {
    case emptySelection
    case couldNotBuildPDF

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select at least one saved Memory."
        case .couldNotBuildPDF:
            return "The selected memories could not be combined into a PDF context bundle."
        }
    }
}

struct MemoryContextBundle: Sendable {
    let fileURLs: [URL]
    let composerTextURL: URL?
    let selectedCount: Int
    let format: MemorySharingFormat

    func statusMessage(for providerName: String) -> String {
        let entryVerb = selectedCount == 1 ? "entry is" : "entries are"
        if format.injectsMarkdownText {
            return "\(selectedCount) Memory \(entryVerb) ready for \(providerName). Tap Paste Context to insert the combined context."
        }

        let names = fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        return "\(selectedCount) Memory \(entryVerb) ready for \(providerName): \(names)."
    }
}

final class MemoryContextBundleBuilder {
    private static let streamChunkSize = 1_048_576

    private let fileManager: FileManager
    private let store: LocalMemoryStore
    private let cache: MemoryContextBundleCache

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.store = LocalMemoryStore(fileManager: fileManager)
        self.cache = MemoryContextBundleCache(fileManager: fileManager)
    }

    func build(entries: [LocalMemoryEntry], format: MemorySharingFormat) throws -> MemoryContextBundle {
        guard !entries.isEmpty else {
            throw MemoryContextBundleError.emptySelection
        }

        let outputFolder = try cache.bundleFolder(for: entries)
        let markdownURL = outputFolder.appendingPathComponent("ContextPort Context.md")
        let pdfURL = outputFolder.appendingPathComponent("ContextPort Context.pdf")
        let composerTextURL = outputFolder.appendingPathComponent("ContextPort Composer Context.txt")

        if format.includesMarkdownFile || format.injectsMarkdownText {
            try buildCombinedMarkdownIfNeeded(entries: entries, to: markdownURL)
        }

        var fileURLs: [URL] = []
        if format.includesPDF {
            try buildCombinedPDFIfNeeded(entries: entries, markdownURL: markdownURL, to: pdfURL)
            fileURLs.append(pdfURL)
        }
        if format.includesMarkdownFile {
            fileURLs.append(markdownURL)
        }

        var pendingComposerTextURL: URL?
        if format.injectsMarkdownText {
            try buildComposerTextIfNeeded(markdownURL: markdownURL, to: composerTextURL)
            pendingComposerTextURL = composerTextURL
        }

        cache.markUsed(outputFolder)
        cache.prune(keeping: outputFolder)

        return MemoryContextBundle(
            fileURLs: fileURLs,
            composerTextURL: pendingComposerTextURL,
            selectedCount: entries.count,
            format: format
        )
    }

    static func composerText(for entries: [LocalMemoryEntry]) -> String {
        do {
            let bundle = try MemoryContextBundleBuilder().build(entries: entries, format: .insertMarkdownText)
            guard let url = bundle.composerTextURL else { return "" }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return ""
        }
    }

    private func buildCombinedMarkdownIfNeeded(entries: [LocalMemoryEntry], to destination: URL) throws {
        guard !cache.isUsableFile(destination) else { return }

        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".markdown-\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryURL)

        do {
            let formatter = ISO8601DateFormatter()
            write(
                "# ContextPort Context Bundle\n\n" +
                "Selected Memories: \(entries.count)\n" +
                "Generated: \(formatter.string(from: Date()))\n\n" +
                "Current instructions override older context. Treat the selected memories and their ordered revisions as historical project context unless the user explicitly says otherwise.\n\n" +
                "---\n\n",
                to: output
            )

            for (entryIndex, entry) in entries.enumerated() {
                if entryIndex > 0 {
                    write("\n\n---\n\n", to: output)
                }
                write(
                    "# Memory \(entryIndex + 1): \(entry.title)\n\n" +
                    "Project: \(entry.projectName)\n" +
                    "Created: \(formatter.string(from: entry.createdAt))\n" +
                    "Updated: \(formatter.string(from: entry.updatedAt))\n" +
                    "Revisions: \(entry.revisionCount)\n\n",
                    to: output
                )

                for (revisionIndex, revision) in entry.orderedRevisions.enumerated() {
                    if revisionIndex > 0 {
                        write("\n\n---\n\n", to: output)
                    }
                    let messageLine = revision.messageCount.map { "Messages: \($0)" } ?? "Messages: unknown"
                    write(
                        "## Revision \(revision.number)\n\n" +
                        "Source: \(revision.source)\n" +
                        "Saved: \(formatter.string(from: revision.createdAt))\n" +
                        "\(messageLine)\n\n",
                        to: output
                    )
                    try streamMarkdown(for: revision, in: entry, to: output)
                }
            }

            output.synchronizeFile()
            output.closeFile()
            try replace(destination, with: temporaryURL)
        } catch {
            output.closeFile()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func buildComposerTextIfNeeded(markdownURL: URL, to destination: URL) throws {
        guard !cache.isUsableFile(destination) else { return }

        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".composer-\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryURL)

        do {
            write(
                "Continue using the selected ContextPort memories below as project memory. Treat them as historical context. Current instructions override older context.\n\n",
                to: output
            )
            try streamFile(at: markdownURL, to: output)
            output.synchronizeFile()
            output.closeFile()
            try replace(destination, with: temporaryURL)
        } catch {
            output.closeFile()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func buildCombinedPDFIfNeeded(
        entries: [LocalMemoryEntry],
        markdownURL: URL,
        to destination: URL
    ) throws {
        guard !cache.isUsableFile(destination) else { return }

        if try MemoryContextPDFCompiler(fileManager: fileManager).compile(entries: entries, to: destination) {
            return
        }

        try buildCombinedMarkdownIfNeeded(entries: entries, to: markdownURL)
        let combinedMarkdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let fallbackEntry = LocalMemoryEntry(
            projectName: "ContextPort",
            title: "ContextPort Context Bundle",
            content: combinedMarkdown,
            source: "contextport-memory-bundle",
            tags: ["context", "memory", "bundle"],
            importance: 5
        )
        try LocalMemoryPDFRenderer.render(entry: fallbackEntry, to: destination)
    }

    private func streamMarkdown(
        for revision: LocalMemoryRevision,
        in entry: LocalMemoryEntry,
        to output: FileHandle
    ) throws {
        if let sourceURL = store.markdownURL(for: revision) {
            try streamFile(at: sourceURL, to: output)
            return
        }
        if revision.number == entry.latestRevision?.number, !entry.content.isEmpty {
            write(entry.content, to: output)
            return
        }
        write("_Revision content is unavailable on this device._", to: output)
    }

    private func streamFile(at sourceURL: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { input.closeFile() }

        while true {
            let data = input.readData(ofLength: Self.streamChunkSize)
            if data.isEmpty { break }
            output.write(data)
        }
    }

    private func write(_ text: String, to output: FileHandle) {
        guard let data = text.data(using: .utf8) else { return }
        output.write(data)
    }

    private func replace(_ destination: URL, with temporaryURL: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }
}
