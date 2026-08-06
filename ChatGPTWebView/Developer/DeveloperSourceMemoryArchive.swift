import CryptoKit
import Foundation

struct DeveloperSourceArchiveItem: Sendable {
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

    var resourceState: String {
        if content != nil { return "indexed_text" }
        if loadError != nil { return "load_error" }
        return "metadata_only"
    }

    var byteCount: Int {
        content?.utf8.count ?? resourceByteCount ?? 0
    }
}

enum DeveloperSourceMemoryArchiveError: LocalizedError {
    case noSources
    case archiveTooLarge
    case tooManyFiles
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "There are no retained developer sources to save."
        case .archiveTooLarge:
            return "The retained source archive is too large for the current ZIP format."
        case .tooManyFiles:
            return "The retained source archive contains too many files for the current ZIP format."
        case .invalidPath:
            return "A source path could not be written to the ZIP archive."
        }
    }
}

final class DeveloperSourceMemoryArchiveBuilder {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    private static let fingerprintTagPrefix = "source-fingerprint:"

    func saveToMemory(items: [DeveloperSourceArchiveItem]) throws -> LocalMemorySaveResult {
        guard !items.isEmpty else {
            throw DeveloperSourceMemoryArchiveError.noSources
        }

        let fingerprint = Self.fingerprint(for: items)
        let fingerprintTag = Self.fingerprintTagPrefix + fingerprint
        let generatedAt = Date()
        let archiveURL = try buildArchive(items: items, generatedAt: generatedAt)
        let sessionCount = Set(items.map(\.sessionTitle)).count
        let loadedCount = items.filter { $0.resourceState == "indexed_text" }.count
        let metadataOnlyCount = items.filter { $0.resourceState == "metadata_only" }.count
        let failedCount = items.filter { $0.resourceState == "load_error" }.count
        let totalBytes = items.reduce(0) { partial, item in
            partial + (item.content?.utf8.count ?? 0)
        }

        let title = sourceMemoryTitle(items: items, generatedAt: generatedAt)
        let summary = sourceMemorySummary(
            items: items,
            generatedAt: generatedAt,
            sessionCount: sessionCount,
            loadedCount: loadedCount,
            metadataOnlyCount: metadataOnlyCount,
            failedCount: failedCount,
            totalBytes: totalBytes,
            fingerprint: fingerprint
        )

        let store = LocalMemoryStore(fileManager: fileManager)
        let existingEntries = try store.loadEntries()
        if let existing = existingEntries.first(where: {
            $0.source == "contextport_dev_sources" && $0.tags.contains(fingerprintTag)
        }) {
            try installArchive(archiveURL, for: existing)
            return LocalMemorySaveResult(
                entry: existing,
                totalCount: existingEntries.count,
                message: "These retained sources are already in Memory. Refreshed the existing Developer Sources ZIP."
            )
        }

        let saved = try store.saveEntry(
            projectName: "Developer Sources",
            title: title,
            content: summary,
            source: "contextport_dev_sources",
            tags: ["developer", "sources", "webview", "ai-debug", "zip", fingerprintTag],
            importance: 5
        )

        do {
            try installArchive(archiveURL, for: saved.entry)
        } catch {
            try? store.deleteEntry(saved.entry)
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }

        return LocalMemorySaveResult(
            entry: saved.entry,
            totalCount: saved.totalCount,
            message: "Saved \(items.count) retained sources to Memory as one ZIP."
        )
    }

    static func fingerprint(for items: [DeveloperSourceArchiveItem]) -> String {
        var hasher = SHA256()
        let sortedItems = items.sorted {
            if $0.id == $1.id {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.id < $1.id
        }

        for item in sortedItems {
            update(&hasher, value: item.id)
            update(&hasher, value: item.sessionTitle)
            update(&hasher, value: item.pageURL)
            update(&hasher, value: item.displayName)
            update(&hasher, value: item.urlString)
            update(&hasher, value: item.kind)
            update(&hasher, value: item.resourceState)
            update(&hasher, value: item.metadataNote)
            update(&hasher, value: item.resourceByteCount.map(String.init))
            update(&hasher, value: item.loadError)

            if let content = item.content {
                hasher.update(data: Data([1]))
                let contentDigest = SHA256.hash(data: Data(content.utf8))
                hasher.update(data: Data(contentDigest))
            } else {
                hasher.update(data: Data([0]))
            }
            hasher.update(data: Data([0x1E]))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, value: String?) {
        if let value {
            hasher.update(data: Data([1]))
            hasher.update(data: Data(value.utf8))
        } else {
            hasher.update(data: Data([0]))
        }
        hasher.update(data: Data([0x1F]))
    }

    private func installArchive(_ archiveURL: URL, for entry: LocalMemoryEntry) throws {
        let destination = Self.archiveURL(for: entry, fileManager: fileManager)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: archiveURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: archiveURL, to: destination)
        }
    }

    static func archiveURL(
        for entry: LocalMemoryEntry,
        fileManager: FileManager = .default
    ) -> URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return support
            .appendingPathComponent("LocalMemoryVault", isDirectory: true)
            .appendingPathComponent("DeveloperSources", isDirectory: true)
            .appendingPathComponent("\(entry.id.uuidString).zip")
    }

    static func existingArchiveURL(
        for entry: LocalMemoryEntry,
        fileManager: FileManager = .default
    ) -> URL? {
        guard entry.tags.contains("sources"),
              entry.source == "contextport_dev_sources" else {
            return nil
        }

        let url = archiveURL(for: entry, fileManager: fileManager)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    static func deleteArchive(
        for entry: LocalMemoryEntry,
        fileManager: FileManager = .default
    ) {
        guard entry.source == "contextport_dev_sources" else { return }
        let url = archiveURL(for: entry, fileManager: fileManager)
        try? fileManager.removeItem(at: url)
    }

    private func buildArchive(
        items: [DeveloperSourceArchiveItem],
        generatedAt: Date
    ) throws -> URL {
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ContextPortDeveloperSourceExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        let archiveURL = exportRoot.appendingPathComponent("ContextPort Loaded Sources.zip")
        let writer = try DeveloperSourceZIPWriter(destination: archiveURL)
        let root = "ContextPort Loaded Sources"

        var manifestEntries: [DeveloperSourceArchiveManifestEntry] = []
        var usedPaths = Set<String>()

        for (index, item) in items.enumerated() {
            let archivePath: String?

            if let content = item.content {
                let sessionFolder = cleanPathComponent(item.sessionTitle, fallback: "Session")
                let preferredName = sourceFileName(for: item, index: index + 1)
                let basePath = "\(root)/Sources/\(sessionFolder)/\(preferredName)"
                let uniquePath = uniqueArchivePath(basePath, usedPaths: &usedPaths)
                try writer.add(data: Data(content.utf8), path: uniquePath)
                archivePath = uniquePath
            } else {
                archivePath = nil
            }

            manifestEntries.append(
                DeveloperSourceArchiveManifestEntry(
                    id: item.id,
                    sessionTitle: item.sessionTitle,
                    pageURL: item.pageURL,
                    displayName: item.displayName,
                    sourceURL: item.urlString,
                    kind: item.kind,
                    state: item.resourceState,
                    byteCount: item.byteCount,
                    archivePath: archivePath,
                    metadataNote: item.metadataNote,
                    loadError: item.loadError
                )
            )
        }

        let manifest = DeveloperSourceArchiveManifest(
            formatVersion: 2,
            generatedAt: generatedAt,
            sourceCount: items.count,
            sessionCount: Set(items.map(\.sessionTitle)).count,
            sources: manifestEntries
        )

        try writer.add(
            data: encoder.encode(manifest),
            path: "\(root)/manifest.json"
        )

        let readme = """
        ContextPort Loaded Sources

        Generated: \(ISO8601DateFormatter().string(from: generatedAt))
        Sources discovered: \(items.count)
        Sessions represented: \(Set(items.map(\.sessionTitle)).count)

        Open manifest.json first. It maps every discovered source to its provider/profile session,
        page URL, source URL, source type, explicit state, byte count, metadata note, load error,
        and path inside this ZIP.

        Sources contains the complete retained source text that ContextPort successfully indexed.
        Metadata-only resources and true load errors remain documented separately in manifest.json
        even when no source text file exists.
        """
        try writer.add(
            data: Data(readme.utf8),
            path: "\(root)/README.txt"
        )

        try writer.finish()
        return archiveURL
    }

    private func sourceMemoryTitle(
        items: [DeveloperSourceArchiveItem],
        generatedAt: Date
    ) -> String {
        let providers = Array(Set(items.map { sessionProviderName($0.sessionTitle) })).sorted()
        let providerLabel: String
        if providers.isEmpty {
            providerLabel = "AI"
        } else if providers.count <= 2 {
            providerLabel = providers.joined(separator: " + ")
        } else {
            providerLabel = "Multi AI"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(providerLabel) Loaded Sources \(formatter.string(from: generatedAt))"
    }

    private func sourceMemorySummary(
        items: [DeveloperSourceArchiveItem],
        generatedAt: Date,
        sessionCount: Int,
        loadedCount: Int,
        metadataOnlyCount: Int,
        failedCount: Int,
        totalBytes: Int,
        fingerprint: String
    ) -> String {
        let sessions = Array(Set(items.map(\.sessionTitle)).sorted())
        let sourceKinds = Dictionary(grouping: items, by: \.kind)
            .map { key, values in "- \(key): \(values.count)" }
            .sorted()
            .joined(separator: "\n")

        let sessionList = sessions.map { "- \($0)" }.joined(separator: "\n")
        let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)

        return """
        # ContextPort Developer Source Capture

        Generated: \(ISO8601DateFormatter().string(from: generatedAt))

        This Memory contains a ZIP attachment with the complete retained browser source index captured by ContextPort Developer Mode.

        ## Capture Summary

        - Sources discovered: \(items.count)
        - Sources with indexed text: \(loadedCount)
        - Metadata-only resources: \(metadataOnlyCount)
        - Sources with load errors: \(failedCount)
        - Browser sessions: \(sessionCount)
        - Indexed source text: \(size)
        - Capture fingerprint: \(fingerprint)

        ## Sessions

        \(sessionList)

        ## Source Types

        \(sourceKinds)

        ## Analysis Note

        Share the attached `ContextPort Loaded Sources.zip` when investigating ChatGPT, Claude, Gemini, Grok, or DeepSeek frontend behavior. Start with `manifest.json` to map source files back to the provider session and source URL.
        """
    }

    private func sessionProviderName(_ sessionTitle: String) -> String {
        sessionTitle.components(separatedBy: " • ").first ?? sessionTitle
    }

    private func sourceFileName(
        for item: DeveloperSourceArchiveItem,
        index: Int
    ) -> String {
        let ext: String
        switch item.kind.lowercased() {
        case let value where value.contains("style"):
            ext = "css"
        case let value where value.contains("javascript") || value.contains("script"):
            ext = "js"
        default:
            ext = "txt"
        }

        var name = cleanPathComponent(
            item.displayName,
            fallback: String(format: "Source %04d", index)
        )

        let currentExtension = URL(fileURLWithPath: name).pathExtension
        if currentExtension.isEmpty {
            name += ".\(ext)"
        }
        return String(name.prefix(140))
    }

    private func cleanPathComponent(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(120))
    }

    private func uniqueArchivePath(
        _ path: String,
        usedPaths: inout Set<String>
    ) -> String {
        if usedPaths.insert(path).inserted {
            return path
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let directory = (path as NSString).deletingLastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        var suffix = 2

        while true {
            let fileName = ext.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(ext)"
            let candidate = "\(directory)/\(fileName)"
            if usedPaths.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }
}

private struct DeveloperSourceArchiveManifest: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let sourceCount: Int
    let sessionCount: Int
    let sources: [DeveloperSourceArchiveManifestEntry]
}

private struct DeveloperSourceArchiveManifestEntry: Codable {
    let id: String
    let sessionTitle: String
    let pageURL: String
    let displayName: String
    let sourceURL: String?
    let kind: String
    let state: String
    let byteCount: Int
    let archivePath: String?
    let metadataNote: String?
    let loadError: String?
}

private final class DeveloperSourceZIPWriter {
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
            throw DeveloperSourceMemoryArchiveError.archiveTooLarge
        }

        let pathData = Data(normalizedPath.utf8)
        let crc = DeveloperSourceCRC32.checksum(data)
        let size = UInt32(data.count)
        let dateParts = Self.dosDateParts(modifiedAt)
        let localOffset = currentOffset

        var header = Data()
        header.appendLittleEndian(UInt32(0x04034B50))
        header.appendLittleEndian(UInt16(20))
        header.appendLittleEndian(UInt16(0x0800))
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(dateParts.time)
        header.appendLittleEndian(dateParts.date)
        header.appendLittleEndian(crc)
        header.appendLittleEndian(size)
        header.appendLittleEndian(size)
        header.appendLittleEndian(UInt16(pathData.count))
        header.appendLittleEndian(UInt16(0))
        header.append(pathData)

        try write(header)
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

    func finish() throws {
        guard !isFinished else { return }
        guard entries.count <= Int(UInt16.max) else {
            throw DeveloperSourceMemoryArchiveError.tooManyFiles
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

    private func normalize(_ path: String) throws -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains("..") else {
            throw DeveloperSourceMemoryArchiveError.invalidPath
        }
        guard Data(normalized.utf8).count <= Int(UInt16.max) else {
            throw DeveloperSourceMemoryArchiveError.invalidPath
        }
        return normalized
    }

    private func write(_ data: Data) throws {
        let nextOffset = UInt64(currentOffset) + UInt64(data.count)
        guard nextOffset <= UInt64(UInt32.max) else {
            throw DeveloperSourceMemoryArchiveError.archiveTooLarge
        }
        try handle.write(contentsOf: data)
        currentOffset = UInt32(nextOffset)
    }

    private static func dosDateParts(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
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

private enum DeveloperSourceCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1
                ? 0xEDB88320 ^ (crc >> 1)
                : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(contentsOf: rawBuffer)
        }
    }
}
