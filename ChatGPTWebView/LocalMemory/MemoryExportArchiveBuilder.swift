import Foundation

struct MemoryExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum MemoryExportArchiveError: LocalizedError {
    case noMemories
    case missingRevisionFiles
    case archiveTooLarge
    case tooManyArchiveEntries
    case invalidArchivePath

    var errorDescription: String? {
        switch self {
        case .noMemories:
            return "There are no Memories to export."
        case .missingRevisionFiles:
            return "The selected revision has no PDF or Markdown file available to export."
        case .archiveTooLarge:
            return "The Memory export is too large for the current ZIP format."
        case .tooManyArchiveEntries:
            return "The Memory export contains too many files for the current ZIP format."
        case .invalidArchivePath:
            return "A Memory export file path could not be written to the ZIP archive."
        }
    }
}

final class MemoryExportArchiveBuilder {
    private let fileManager: FileManager
    private let store: LocalMemoryStore
    private let exportRoot: URL
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.store = LocalMemoryStore(fileManager: fileManager)
        self.exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ContextPortMemoryExports", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func exportAll(entries: [LocalMemoryEntry]) throws -> URL {
        guard !entries.isEmpty else {
            throw MemoryExportArchiveError.noMemories
        }

        let exportFolder = try makeExportFolder()
        let archiveURL = exportFolder.appendingPathComponent("ContextPort Memories.zip")
        let writer = try SimpleZIPWriter(destination: archiveURL)
        let generatedAt = Date()

        let archiveManifest = MemoryArchiveManifest(
            formatVersion: 1,
            generatedAt: generatedAt,
            memoryCount: entries.count,
            revisionCount: entries.reduce(0) { $0 + $1.revisionCount }
        )
        try writer.add(data: encoder.encode(archiveManifest), path: "ContextPort Memories/manifest.json")

        let readme = """
        ContextPort Memory Export

        Generated: \(ISO8601DateFormatter().string(from: generatedAt))
        Memories: \(entries.count)

        Each Memory folder contains memory.json and one folder per saved revision.
        Each revision folder contains revision.json plus the saved context.pdf and/or context.md files available on this device.
        """
        try writer.add(data: Data(readme.utf8), path: "ContextPort Memories/README.txt")

        for entry in entries.sorted(by: memoryExportSort) {
            let memoryFolder = "ContextPort Memories/Memories/\(memoryFolderName(for: entry))"
            try writer.add(
                data: encoder.encode(MemoryArchiveMetadata(entry: entry)),
                path: "\(memoryFolder)/memory.json"
            )

            for revision in entry.orderedRevisions {
                try addRevision(
                    entry: entry,
                    revision: revision,
                    rootFolder: memoryFolder,
                    writer: writer
                )
            }
        }

        try writer.finish()
        return archiveURL
    }

    func exportRevision(entry: LocalMemoryEntry, revision: LocalMemoryRevision) throws -> URL {
        let pdfURL = store.pdfURL(for: revision)
        let markdownURL = store.markdownURL(for: revision)
        guard pdfURL != nil || markdownURL != nil else {
            throw MemoryExportArchiveError.missingRevisionFiles
        }

        let exportFolder = try makeExportFolder()
        let baseName = cleanFileName("\(entry.title) - Revision \(revision.number)", fallback: "ContextPort Revision \(revision.number)")
        let archiveURL = exportFolder.appendingPathComponent("\(baseName).zip")
        let writer = try SimpleZIPWriter(destination: archiveURL)
        let rootFolder = baseName

        try writer.add(
            data: encoder.encode(MemoryArchiveMetadata(entry: entry)),
            path: "\(rootFolder)/memory.json"
        )
        try writer.add(
            data: encoder.encode(RevisionArchiveMetadata(revision: revision)),
            path: "\(rootFolder)/revision.json"
        )

        if let pdfURL {
            try writer.add(file: pdfURL, path: "\(rootFolder)/context.pdf")
        }
        if let markdownURL {
            try writer.add(file: markdownURL, path: "\(rootFolder)/context.md")
        }

        try writer.finish()
        return archiveURL
    }

    private func addRevision(
        entry: LocalMemoryEntry,
        revision: LocalMemoryRevision,
        rootFolder: String,
        writer: SimpleZIPWriter
    ) throws {
        let revisionFolder = String(format: "Revision %03d", revision.number)
        let path = "\(rootFolder)/\(revisionFolder)"

        try writer.add(
            data: encoder.encode(RevisionArchiveMetadata(revision: revision)),
            path: "\(path)/revision.json"
        )

        if let pdfURL = store.pdfURL(for: revision) {
            try writer.add(file: pdfURL, path: "\(path)/context.pdf")
        }
        if let markdownURL = store.markdownURL(for: revision) {
            try writer.add(file: markdownURL, path: "\(path)/context.md")
        }
    }

    private func makeExportFolder() throws -> URL {
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let folder = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func memoryFolderName(for entry: LocalMemoryEntry) -> String {
        let title = cleanFileName(entry.title, fallback: "Memory")
        return "\(title) [\(entry.id.uuidString.prefix(8))]"
    }

    private func cleanFileName(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(96))
    }

    private func memoryExportSort(_ lhs: LocalMemoryEntry, _ rhs: LocalMemoryEntry) -> Bool {
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder == .orderedSame {
            return lhs.createdAt < rhs.createdAt
        }
        return titleOrder == .orderedAscending
    }
}

private struct MemoryArchiveManifest: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let memoryCount: Int
    let revisionCount: Int
}

private struct MemoryArchiveMetadata: Codable {
    let id: UUID
    let projectName: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let isFavorite: Bool
    let revisionCount: Int
    let tags: [String]
    let importance: Int

    init(entry: LocalMemoryEntry) {
        self.id = entry.id
        self.projectName = entry.projectName
        self.title = entry.title
        self.createdAt = entry.createdAt
        self.updatedAt = entry.updatedAt
        self.isFavorite = entry.isFavorite
        self.revisionCount = entry.revisionCount
        self.tags = entry.tags
        self.importance = entry.importance
    }
}

private struct RevisionArchiveMetadata: Codable {
    let id: UUID
    let number: Int
    let createdAt: Date
    let source: String
    let messageCount: Int?
    let exportedAt: String?
    let includesPDF: Bool
    let includesMarkdown: Bool

    init(revision: LocalMemoryRevision) {
        self.id = revision.id
        self.number = revision.number
        self.createdAt = revision.createdAt
        self.source = revision.source
        self.messageCount = revision.messageCount
        self.exportedAt = revision.exportedAt
        self.includesPDF = revision.pdfFilename != nil
        self.includesMarkdown = revision.markdownFilename != nil
    }
}

private final class SimpleZIPWriter {
    private struct CentralDirectoryEntry {
        let pathData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private let handle: FileHandle
    private var entries: [CentralDirectoryEntry] = []
    private var currentOffset: UInt32 = 0
    private var isFinished = false

    init(destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: destination)
    }

    deinit {
        try? handle.close()
    }

    func add(data: Data, path: String, modifiedAt: Date = Date()) throws {
        let normalizedPath = try normalize(path)
        guard data.count <= Int(UInt32.max) else {
            throw MemoryExportArchiveError.archiveTooLarge
        }

        let pathData = Data(normalizedPath.utf8)
        let crc = CRC32.checksum(data)
        let size = UInt32(data.count)
        let dateParts = Self.dosDateParts(modifiedAt)
        let localOffset = currentOffset

        try writeLocalHeader(
            pathData: pathData,
            crc32: crc,
            size: size,
            dosTime: dateParts.time,
            dosDate: dateParts.date
        )
        try write(data)

        entries.append(
            CentralDirectoryEntry(
                pathData: pathData,
                crc32: crc,
                size: size,
                localHeaderOffset: localOffset,
                dosTime: dateParts.time,
                dosDate: dateParts.date
            )
        )
    }

    func add(file: URL, path: String) throws {
        let normalizedPath = try normalize(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize <= UInt64(UInt32.max) else {
            throw MemoryExportArchiveError.archiveTooLarge
        }

        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
        let pathData = Data(normalizedPath.utf8)
        let crc = try CRC32.checksum(file: file)
        let size = UInt32(fileSize)
        let dateParts = Self.dosDateParts(modifiedAt)
        let localOffset = currentOffset

        try writeLocalHeader(
            pathData: pathData,
            crc32: crc,
            size: size,
            dosTime: dateParts.time,
            dosDate: dateParts.date
        )

        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try write(chunk)
        }

        entries.append(
            CentralDirectoryEntry(
                pathData: pathData,
                crc32: crc,
                size: size,
                localHeaderOffset: localOffset,
                dosTime: dateParts.time,
                dosDate: dateParts.date
            )
        )
    }

    func finish() throws {
        guard !isFinished else { return }
        guard entries.count <= Int(UInt16.max) else {
            throw MemoryExportArchiveError.tooManyArchiveEntries
        }

        let centralDirectoryOffset = currentOffset

        for entry in entries {
            var header = Data()
            header.appendLittleEndian(UInt32(0x02014B50))
            header.appendLittleEndian(UInt16(20))
            header.appendLittleEndian(UInt16(20))
            header.appendLittleEndian(UInt16(0x0800))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(entry.dosTime)
            header.appendLittleEndian(entry.dosDate)
            header.appendLittleEndian(entry.crc32)
            header.appendLittleEndian(entry.size)
            header.appendLittleEndian(entry.size)
            header.appendLittleEndian(UInt16(entry.pathData.count))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt32(0))
            header.appendLittleEndian(entry.localHeaderOffset)
            header.append(entry.pathData)
            try write(header)
        }

        let centralDirectorySize = currentOffset - centralDirectoryOffset
        let entryCount = UInt16(entries.count)

        var end = Data()
        end.appendLittleEndian(UInt32(0x06054B50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(entryCount)
        end.appendLittleEndian(entryCount)
        end.appendLittleEndian(centralDirectorySize)
        end.appendLittleEndian(centralDirectoryOffset)
        end.appendLittleEndian(UInt16(0))
        try write(end)
        try handle.synchronize()
        try handle.close()
        isFinished = true
    }

    private func writeLocalHeader(
        pathData: Data,
        crc32: UInt32,
        size: UInt32,
        dosTime: UInt16,
        dosDate: UInt16
    ) throws {
        guard pathData.count <= Int(UInt16.max) else {
            throw MemoryExportArchiveError.invalidArchivePath
        }

        var header = Data()
        header.appendLittleEndian(UInt32(0x04034B50))
        header.appendLittleEndian(UInt16(20))
        header.appendLittleEndian(UInt16(0x0800))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(dosTime)
        header.appendLittleEndian(dosDate)
        header.appendLittleEndian(crc32)
        header.appendLittleEndian(size)
        header.appendLittleEndian(size)
        header.appendLittleEndian(UInt16(pathData.count))
        header.appendLittleEndian(UInt16(0))
        header.append(pathData)
        try write(header)
    }

    private func write(_ data: Data) throws {
        guard UInt64(currentOffset) + UInt64(data.count) <= UInt64(UInt32.max) else {
            throw MemoryExportArchiveError.archiveTooLarge
        }
        try handle.write(contentsOf: data)
        currentOffset += UInt32(data.count)
    }

    private func normalize(_ path: String) throws -> String {
        let normalized = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")

        guard !normalized.isEmpty, Data(normalized.utf8).count <= Int(UInt16.max) else {
            throw MemoryExportArchiveError.invalidArchivePath
        }
        return normalized
    }

    private static func dosDateParts(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: .current, from: date)
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59)

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        crc = update(crc, with: data)
        return crc ^ UInt32.max
    }

    static func checksum(file: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var crc = UInt32.max
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            crc = update(crc, with: chunk)
        }
        return crc ^ UInt32.max
    }

    private static func update(_ initial: UInt32, with data: Data) -> UInt32 {
        var crc = initial
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
