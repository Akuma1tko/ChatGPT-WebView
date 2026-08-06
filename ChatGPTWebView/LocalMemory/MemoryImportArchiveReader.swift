import Foundation

struct MemoryImportResult: Sendable, Hashable {
    let memoriesCreated: Int
    let memoriesUpdated: Int
    let revisionsImported: Int
    let revisionsSkipped: Int

    var message: String {
        let revisionNoun = revisionsImported == 1 ? "revision" : "revisions"
        let memoryCount = memoriesCreated + memoriesUpdated
        let memoryNoun = memoryCount == 1 ? "Memory entry" : "Memory entries"
        let skippedNoun = revisionsSkipped == 1 ? "revision" : "revisions"
        return "Imported \(revisionsImported) \(revisionNoun) across \(memoryCount) \(memoryNoun). Skipped \(revisionsSkipped) existing \(skippedNoun)."
    }
}

enum MemoryImportArchiveError: LocalizedError {
    case unsupportedArchive
    case unsupportedFormatVersion(Int)
    case unsafeArchivePath
    case corruptArchive
    case invalidMemoryMetadata
    case noMemoryPackages

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive:
            return "This ZIP is not a supported ContextPort Memory export."
        case .unsupportedFormatVersion(let version):
            return "This ContextPort Memory ZIP uses unsupported format version \(version)."
        case .unsafeArchivePath:
            return "The Memory ZIP contains an unsafe file path."
        case .corruptArchive:
            return "The Memory ZIP is incomplete or corrupt."
        case .invalidMemoryMetadata:
            return "The Memory ZIP contains invalid Memory or revision metadata."
        case .noMemoryPackages:
            return "No importable ContextPort Memories were found in the ZIP."
        }
    }
}

struct MemoryImportPackage: Sendable {
    let metadata: ImportedMemoryMetadata
    let revisions: [MemoryImportRevision]
}

struct MemoryImportRevision: Sendable {
    let metadata: ImportedRevisionMetadata
    let pdfURL: URL?
    let markdownURL: URL?
}

struct ImportedMemoryMetadata: Codable, Sendable {
    let id: UUID
    let projectName: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let isFavorite: Bool
    let revisionCount: Int
    let tags: [String]
    let importance: Int
}

struct ImportedRevisionMetadata: Codable, Sendable {
    let id: UUID
    let number: Int
    let createdAt: Date
    let source: String
    let messageCount: Int?
    let exportedAt: String?
    let includesPDF: Bool
    let includesMarkdown: Bool
}

final class MemoryImportArchiveReader {
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func importArchive(at archiveURL: URL) throws -> MemoryImportResult {
        let importRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ContextPortMemoryImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: importRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: importRoot) }

        try StoredZIPExtractor(fileManager: fileManager).extract(archiveURL: archiveURL, to: importRoot)
        try validateFormatVersion(in: importRoot)
        let packages = try loadPackages(from: importRoot)
        guard !packages.isEmpty else {
            throw MemoryImportArchiveError.noMemoryPackages
        }

        let writer = MemoryImportVaultWriter(fileManager: fileManager)
        var memoriesCreated = 0
        var memoriesUpdated = 0
        var revisionsImported = 0
        var revisionsSkipped = 0

        for package in packages {
            let result = try writer.importPackage(package)
            memoriesCreated += result.createdMemory ? 1 : 0
            memoriesUpdated += result.updatedMemory ? 1 : 0
            revisionsImported += result.revisionsImported
            revisionsSkipped += result.revisionsSkipped
        }

        return MemoryImportResult(
            memoriesCreated: memoriesCreated,
            memoriesUpdated: memoriesUpdated,
            revisionsImported: revisionsImported,
            revisionsSkipped: revisionsSkipped
        )
    }

    private func validateFormatVersion(in root: URL) throws {
        let manifestURLs = try recursiveFiles(in: root).filter { $0.lastPathComponent == "manifest.json" }
        guard let manifestURL = manifestURLs.first else {
            return
        }

        struct Manifest: Decodable {
            let formatVersion: Int
        }

        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == 1 else {
            throw MemoryImportArchiveError.unsupportedFormatVersion(manifest.formatVersion)
        }
    }

    private func loadPackages(from root: URL) throws -> [MemoryImportPackage] {
        let files = try recursiveFiles(in: root)
        let memoryMetadataURLs = files.filter { $0.lastPathComponent == "memory.json" }
        var packages: [MemoryImportPackage] = []

        for memoryURL in memoryMetadataURLs {
            let metadata: ImportedMemoryMetadata
            do {
                metadata = try decoder.decode(ImportedMemoryMetadata.self, from: Data(contentsOf: memoryURL))
            } catch {
                throw MemoryImportArchiveError.invalidMemoryMetadata
            }

            let memoryFolder = memoryURL.deletingLastPathComponent()
            let directRevisionURL = memoryFolder.appendingPathComponent("revision.json")
            var revisionFolders: [URL] = []

            if fileManager.fileExists(atPath: directRevisionURL.path) {
                revisionFolders = [memoryFolder]
            } else {
                let children = try fileManager.contentsOfDirectory(
                    at: memoryFolder,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                revisionFolders = children.filter { child in
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                    guard values?.isDirectory == true else { return false }
                    return fileManager.fileExists(
                        atPath: child.appendingPathComponent("revision.json").path
                    )
                }
            }

            let revisions = try revisionFolders.compactMap { folder -> MemoryImportRevision? in
                let revisionMetadataURL = folder.appendingPathComponent("revision.json")
                guard fileManager.fileExists(atPath: revisionMetadataURL.path) else { return nil }

                let revisionMetadata: ImportedRevisionMetadata
                do {
                    revisionMetadata = try decoder.decode(
                        ImportedRevisionMetadata.self,
                        from: Data(contentsOf: revisionMetadataURL)
                    )
                } catch {
                    throw MemoryImportArchiveError.invalidMemoryMetadata
                }

                let pdfURL = existingFile(folder.appendingPathComponent("context.pdf"))
                let markdownURL = existingFile(folder.appendingPathComponent("context.md"))
                guard pdfURL != nil || markdownURL != nil else {
                    return nil
                }

                return MemoryImportRevision(
                    metadata: revisionMetadata,
                    pdfURL: pdfURL,
                    markdownURL: markdownURL
                )
            }

            if !revisions.isEmpty {
                packages.append(
                    MemoryImportPackage(
                        metadata: metadata,
                        revisions: revisions.sorted { $0.metadata.number < $1.metadata.number }
                    )
                )
            }
        }

        return packages
    }

    private func existingFile(_ url: URL) -> URL? {
        fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func recursiveFiles(in root: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }
}

private struct MemoryPackageWriteResult {
    let createdMemory: Bool
    let updatedMemory: Bool
    let revisionsImported: Int
    let revisionsSkipped: Int
}

private final class MemoryImportVaultWriter {
    private let fileManager: FileManager
    private let pdfs: URL
    private let markdown: URL
    private let index: URL
    private let encoder: JSONEncoder

    init(fileManager: FileManager) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let root = support.appendingPathComponent("LocalMemoryVault", isDirectory: true)
        self.pdfs = root.appendingPathComponent("PDFs", isDirectory: true)
        self.markdown = root.appendingPathComponent("Markdown", isDirectory: true)
        self.index = root.appendingPathComponent("entries.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func importPackage(_ package: MemoryImportPackage) throws -> MemoryPackageWriteResult {
        try ensureFolders()
        var entries = try LocalMemoryStore(fileManager: fileManager).loadEntries()
        let existingIndex = entries.firstIndex { $0.id == package.metadata.id }

        if let existingIndex {
            var entry = entries[existingIndex]
            let favoriteChanged = package.metadata.isFavorite && !entry.isFavorite
            entry.isFavorite = entry.isFavorite || package.metadata.isFavorite

            var existingRevisionIDs = Set(entry.revisions.map(\.id))
            var usedNumbers = Set(entry.revisions.map(\.number))
            var importedCount = 0
            var skippedCount = 0

            for importedRevision in package.revisions.sorted(by: revisionSort) {
                guard !existingRevisionIDs.contains(importedRevision.metadata.id) else {
                    skippedCount += 1
                    continue
                }

                let resolvedNumber = resolveRevisionNumber(
                    requested: importedRevision.metadata.number,
                    usedNumbers: &usedNumbers
                )
                let revision = try copyRevision(importedRevision, resolvedNumber: resolvedNumber)
                entry.revisions.append(revision)
                existingRevisionIDs.insert(revision.id)
                importedCount += 1
            }

            entry.revisions.sort { $0.number < $1.number }
            refreshLatestSnapshot(&entry, importedMetadata: package.metadata)
            entries[existingIndex] = entry
            try write(entries)

            return MemoryPackageWriteResult(
                createdMemory: false,
                updatedMemory: importedCount > 0 || favoriteChanged,
                revisionsImported: importedCount,
                revisionsSkipped: skippedCount
            )
        }

        var usedNumbers = Set<Int>()
        var revisionIDs = Set<UUID>()
        var revisions: [LocalMemoryRevision] = []
        var skippedCount = 0

        for importedRevision in package.revisions.sorted(by: revisionSort) {
            guard !revisionIDs.contains(importedRevision.metadata.id) else {
                skippedCount += 1
                continue
            }

            let resolvedNumber = resolveRevisionNumber(
                requested: importedRevision.metadata.number,
                usedNumbers: &usedNumbers
            )
            let revision = try copyRevision(importedRevision, resolvedNumber: resolvedNumber)
            revisions.append(revision)
            revisionIDs.insert(revision.id)
        }

        guard !revisions.isEmpty else {
            return MemoryPackageWriteResult(
                createdMemory: false,
                updatedMemory: false,
                revisionsImported: 0,
                revisionsSkipped: skippedCount
            )
        }

        revisions.sort { $0.number < $1.number }
        let latest = revisions.last
        let latestContent = latest.flatMap(markdownText) ?? ""
        let attachments = revisions.flatMap { revision in
            [revision.pdfFilename, revision.markdownFilename].compactMap { $0 }
        }
        let updatedAt = max(package.metadata.updatedAt, latest?.createdAt ?? package.metadata.updatedAt)

        let entry = LocalMemoryEntry(
            id: package.metadata.id,
            projectName: package.metadata.projectName,
            title: package.metadata.title,
            content: latestContent,
            source: latest?.source ?? "contextport-import",
            tags: package.metadata.tags,
            importance: package.metadata.importance,
            createdAt: package.metadata.createdAt,
            updatedAt: updatedAt,
            pdfFilename: latest?.pdfFilename,
            markdownFilename: latest?.markdownFilename,
            messageCount: latest?.messageCount,
            exportedAt: latest?.exportedAt,
            attachmentFilenames: Array(Set(attachments)).sorted(),
            isFavorite: package.metadata.isFavorite,
            revisions: revisions
        )
        entries.append(entry)
        try write(entries)

        return MemoryPackageWriteResult(
            createdMemory: true,
            updatedMemory: false,
            revisionsImported: revisions.count,
            revisionsSkipped: skippedCount
        )
    }

    private func copyRevision(
        _ importedRevision: MemoryImportRevision,
        resolvedNumber: Int
    ) throws -> LocalMemoryRevision {
        let revisionID = importedRevision.metadata.id
        let pdfName = importedRevision.pdfURL == nil ? nil : "\(revisionID.uuidString).pdf"
        let markdownName = importedRevision.markdownURL == nil ? nil : "\(revisionID.uuidString).md"

        if let source = importedRevision.pdfURL, let pdfName {
            try replaceFile(source: source, destination: pdfs.appendingPathComponent(pdfName))
        }
        if let source = importedRevision.markdownURL, let markdownName {
            try replaceFile(source: source, destination: markdown.appendingPathComponent(markdownName))
        }

        return LocalMemoryRevision(
            id: revisionID,
            number: resolvedNumber,
            createdAt: importedRevision.metadata.createdAt,
            source: importedRevision.metadata.source,
            pdfFilename: pdfName,
            markdownFilename: markdownName,
            messageCount: importedRevision.metadata.messageCount,
            exportedAt: importedRevision.metadata.exportedAt
        )
    }

    private func resolveRevisionNumber(requested: Int, usedNumbers: inout Set<Int>) -> Int {
        let normalizedRequested = max(requested, 1)
        if !usedNumbers.contains(normalizedRequested) {
            usedNumbers.insert(normalizedRequested)
            return normalizedRequested
        }

        var nextNumber = (usedNumbers.max() ?? 0) + 1
        while usedNumbers.contains(nextNumber) {
            nextNumber += 1
        }
        usedNumbers.insert(nextNumber)
        return nextNumber
    }

    private func refreshLatestSnapshot(
        _ entry: inout LocalMemoryEntry,
        importedMetadata: ImportedMemoryMetadata
    ) {
        guard let latest = entry.latestRevision else { return }
        entry.content = markdownText(for: latest) ?? ""
        entry.source = latest.source
        entry.updatedAt = max(entry.updatedAt, max(importedMetadata.updatedAt, latest.createdAt))
        entry.pdfFilename = latest.pdfFilename
        entry.markdownFilename = latest.markdownFilename
        entry.messageCount = latest.messageCount
        entry.exportedAt = latest.exportedAt
        entry.attachmentFilenames = Array(
            Set(
                entry.revisions.flatMap { revision in
                    [revision.pdfFilename, revision.markdownFilename].compactMap { $0 }
                }
            )
        ).sorted()
    }

    private func markdownText(for revision: LocalMemoryRevision) -> String? {
        guard let filename = revision.markdownFilename else { return nil }
        return try? String(
            contentsOf: markdown.appendingPathComponent(filename),
            encoding: .utf8
        )
    }

    private func revisionSort(_ lhs: MemoryImportRevision, _ rhs: MemoryImportRevision) -> Bool {
        if lhs.metadata.number == rhs.metadata.number {
            return lhs.metadata.createdAt < rhs.metadata.createdAt
        }
        return lhs.metadata.number < rhs.metadata.number
    }

    private func replaceFile(source: URL, destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func ensureFolders() throws {
        try fileManager.createDirectory(at: pdfs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: markdown, withIntermediateDirectories: true)
    }

    private func write(_ entries: [LocalMemoryEntry]) throws {
        let data = try encoder.encode(entries.sorted { $0.updatedAt > $1.updatedAt })
        try data.write(to: index, options: [.atomic])
    }
}

private final class StoredZIPExtractor {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func extract(archiveURL: URL, to destinationRoot: URL) throws {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        var extractedFiles = 0

        while true {
            guard let signatureData = try handle.read(upToCount: 4), !signatureData.isEmpty else {
                break
            }
            guard signatureData.count == 4 else {
                throw MemoryImportArchiveError.corruptArchive
            }

            let signature = signatureData.littleEndianUInt32(at: 0)
            if signature == 0x02014B50 || signature == 0x06054B50 {
                break
            }
            guard signature == 0x04034B50 else {
                throw MemoryImportArchiveError.unsupportedArchive
            }

            let header = try readExact(26, from: handle)
            let flags = header.littleEndianUInt16(at: 2)
            let method = header.littleEndianUInt16(at: 4)
            let expectedCRC = header.littleEndianUInt32(at: 10)
            let compressedSize = header.littleEndianUInt32(at: 14)
            let uncompressedSize = header.littleEndianUInt32(at: 18)
            let nameLength = Int(header.littleEndianUInt16(at: 22))
            let extraLength = Int(header.littleEndianUInt16(at: 24))

            guard (flags & 0x0001) == 0, (flags & 0x0008) == 0, method == 0 else {
                throw MemoryImportArchiveError.unsupportedArchive
            }
            guard compressedSize == uncompressedSize else {
                throw MemoryImportArchiveError.unsupportedArchive
            }

            let nameData = try readExact(nameLength, from: handle)
            guard let path = String(data: nameData, encoding: .utf8) else {
                throw MemoryImportArchiveError.corruptArchive
            }
            if extraLength > 0 {
                _ = try readExact(extraLength, from: handle)
            }

            let destination = try safeDestination(for: path, root: destinationRoot)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)

            do {
                var remaining = Int64(uncompressedSize)
                var crc = UInt32.max
                while remaining > 0 {
                    let nextCount = Int(min(remaining, 1_048_576))
                    let chunk = try readExact(nextCount, from: handle)
                    try output.write(contentsOf: chunk)
                    crc = ImportCRC32.update(crc, with: chunk)
                    remaining -= Int64(chunk.count)
                }
                try output.close()

                guard (crc ^ UInt32.max) == expectedCRC else {
                    throw MemoryImportArchiveError.corruptArchive
                }
            } catch {
                try? output.close()
                throw error
            }

            extractedFiles += 1
        }

        guard extractedFiles > 0 else {
            throw MemoryImportArchiveError.unsupportedArchive
        }
    }

    private func readExact(_ count: Int, from handle: FileHandle) throws -> Data {
        if count == 0 { return Data() }

        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw MemoryImportArchiveError.corruptArchive
            }
            result.append(chunk)
        }
        return result
    }

    private func safeDestination(for path: String, root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\0") else {
            throw MemoryImportArchiveError.unsafeArchivePath
        }

        let normalizedComponents = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !normalizedComponents.isEmpty,
              !normalizedComponents.contains("."),
              !normalizedComponents.contains("..") else {
            throw MemoryImportArchiveError.unsafeArchivePath
        }

        var destination = root
        for component in normalizedComponents {
            destination.appendPathComponent(component, isDirectory: false)
        }

        let rootPath = root.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else {
            throw MemoryImportArchiveError.unsafeArchivePath
        }
        return destination
    }
}

private enum ImportCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func update(_ initial: UInt32, with data: Data) -> UInt32 {
        var crc = initial
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
