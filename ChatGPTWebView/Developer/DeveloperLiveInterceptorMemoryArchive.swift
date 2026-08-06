import CryptoKit
import Foundation

private struct DeveloperLiveArchiveManifest: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let retainedEventCount: Int
    let droppedEventCount: Int
    let sessionCount: Int
    let containsBodyPreviews: Bool
    let captureFingerprint: String
    let events: [DeveloperLiveArchiveManifestEntry]
}

private struct DeveloperLiveArchiveManifestEntry: Codable {
    let id: String
    let sequence: Int
    let sessionID: String
    let sessionTitle: String
    let pageURL: String
    let timestamp: Date
    let kind: String
    let phase: String
    let method: String?
    let url: String?
    let status: Int?
    let durationMilliseconds: Double?
    let mimeType: String?
    let transferSize: Int?
    let hasRequestBodyPreview: Bool
    let hasResponseBodyPreview: Bool
    let archivePath: String
}

private struct DeveloperLiveArchiveSummary: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let retainedEventCount: Int
    let droppedEventCount: Int
    let sessions: [String]
    let eventKinds: [String: Int]
    let eventsWithBodyPreviews: Int
    let captureFingerprint: String
}

enum DeveloperLiveMemoryArchiveError: LocalizedError {
    case noEvents
    case archiveTooLarge
    case tooManyFiles
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .noEvents:
            return "There are no retained live interceptor events to save."
        case .archiveTooLarge:
            return "The retained live interceptor archive is too large for the current ZIP format."
        case .tooManyFiles:
            return "The retained live interceptor archive contains too many files for the current ZIP format."
        case .invalidPath:
            return "A live interceptor archive path could not be written."
        }
    }
}

final class DeveloperLiveInterceptorMemoryArchiveBuilder {
    private static let fingerprintTagPrefix = "live-interceptor-fingerprint:"

    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func saveToMemory(
        events: [DeveloperLiveNetworkEvent],
        droppedEventCount: Int
    ) throws -> LocalMemorySaveResult {
        guard !events.isEmpty else {
            throw DeveloperLiveMemoryArchiveError.noEvents
        }

        let fingerprint = Self.fingerprint(
            events: events,
            droppedEventCount: droppedEventCount
        )
        let fingerprintTag = Self.fingerprintTagPrefix + fingerprint
        let generatedAt = Date()
        let archiveURL = try buildArchive(
            events: events,
            droppedEventCount: droppedEventCount,
            generatedAt: generatedAt,
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
                message: "This complete live capture is already in Memory. Refreshed the existing Live Interceptor ZIP."
            )
        }

        let saved = try store.saveEntry(
            projectName: "Developer Live Traffic",
            title: memoryTitle(events: events, generatedAt: generatedAt),
            content: memorySummary(
                events: events,
                droppedEventCount: droppedEventCount,
                generatedAt: generatedAt,
                fingerprint: fingerprint
            ),
            source: "contextport_dev_sources",
            tags: [
                "developer",
                "sources",
                "live-interceptor",
                "webview",
                "ai-debug",
                "network",
                "zip",
                fingerprintTag
            ],
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
            message: "Saved all \(events.count) retained live event\(events.count == 1 ? "" : "s") to Memory as one ZIP."
        )
    }

    static func fingerprint(
        events: [DeveloperLiveNetworkEvent],
        droppedEventCount: Int
    ) -> String {
        var hasher = SHA256()
        update(&hasher, value: String(droppedEventCount))

        for event in events {
            update(&hasher, value: event.id)
            update(&hasher, value: event.sessionID)
            update(&hasher, value: event.sessionTitle)
            update(&hasher, value: event.pageURL)
            update(&hasher, value: String(format: "%.6f", event.timestamp.timeIntervalSince1970))
            update(&hasher, value: event.kind)
            update(&hasher, value: event.phase)
            update(&hasher, value: event.method)
            update(&hasher, value: event.url)
            update(&hasher, value: event.status.map(String.init))
            update(&hasher, value: event.durationMilliseconds.map { String(format: "%.6f", $0) })
            update(&hasher, value: event.mimeType)
            update(&hasher, value: event.transferSize.map(String.init))
            updateDigest(&hasher, value: event.requestBodyPreview)
            updateDigest(&hasher, value: event.responseBodyPreview)
            updateDigest(&hasher, value: event.detail)
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

    private static func updateDigest(_ hasher: inout SHA256, value: String?) {
        guard let value else {
            hasher.update(data: Data([0]))
            hasher.update(data: Data([0x1F]))
            return
        }

        hasher.update(data: Data([1]))
        let digest = SHA256.hash(data: Data(value.utf8))
        hasher.update(data: Data(digest))
        hasher.update(data: Data([0x1F]))
    }

    private func buildArchive(
        events: [DeveloperLiveNetworkEvent],
        droppedEventCount: Int,
        generatedAt: Date,
        fingerprint: String
    ) throws -> URL {
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ContextPortLiveInterceptorExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        let archiveURL = exportRoot.appendingPathComponent("ContextPort Live Interceptor.zip")
        let writer = try DeveloperLiveZIPWriter(destination: archiveURL)
        let root = "ContextPort Live Interceptor"
        var usedPaths = Set<String>()
        var manifestEntries: [DeveloperLiveArchiveManifestEntry] = []
        manifestEntries.reserveCapacity(events.count)

        for (index, event) in events.enumerated() {
            let sessionFolder = cleanPathComponent(event.sessionTitle, fallback: "Session")
            let kind = cleanPathComponent(event.kind, fallback: "event")
            let phase = cleanPathComponent(event.phase, fallback: "event")
            let fileName = String(format: "%04d %@ %@.json", index + 1, kind, phase)
            let basePath = "\(root)/Events/\(sessionFolder)/\(fileName)"
            let archivePath = uniqueArchivePath(basePath, usedPaths: &usedPaths)
            try writer.add(data: encoder.encode(event), path: archivePath, modifiedAt: event.timestamp)

            manifestEntries.append(
                DeveloperLiveArchiveManifestEntry(
                    id: event.id,
                    sequence: index + 1,
                    sessionID: event.sessionID,
                    sessionTitle: event.sessionTitle,
                    pageURL: event.pageURL,
                    timestamp: event.timestamp,
                    kind: event.kind,
                    phase: event.phase,
                    method: event.method,
                    url: event.url,
                    status: event.status,
                    durationMilliseconds: event.durationMilliseconds,
                    mimeType: event.mimeType,
                    transferSize: event.transferSize,
                    hasRequestBodyPreview: event.requestBodyPreview != nil,
                    hasResponseBodyPreview: event.responseBodyPreview != nil,
                    archivePath: archivePath
                )
            )
        }

        let sessions = Array(Set(events.map(\.sessionTitle))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let eventKinds = Dictionary(grouping: events, by: \.kind)
            .mapValues { $0.count }
        let eventsWithBodyPreviews = events.filter {
            $0.requestBodyPreview != nil || $0.responseBodyPreview != nil
        }.count

        let captureSummary = DeveloperLiveArchiveSummary(
            formatVersion: 1,
            generatedAt: generatedAt,
            retainedEventCount: events.count,
            droppedEventCount: droppedEventCount,
            sessions: sessions,
            eventKinds: eventKinds,
            eventsWithBodyPreviews: eventsWithBodyPreviews,
            captureFingerprint: fingerprint
        )
        try writer.add(
            data: encoder.encode(captureSummary),
            path: "\(root)/capture-summary.json"
        )

        let manifest = DeveloperLiveArchiveManifest(
            formatVersion: 1,
            generatedAt: generatedAt,
            retainedEventCount: events.count,
            droppedEventCount: droppedEventCount,
            sessionCount: sessions.count,
            containsBodyPreviews: eventsWithBodyPreviews > 0,
            captureFingerprint: fingerprint,
            events: manifestEntries
        )
        try writer.add(
            data: encoder.encode(manifest),
            path: "\(root)/manifest.json"
        )

        let readme = """
        ContextPort Live Interceptor

        Generated: \(ISO8601DateFormatter().string(from: generatedAt))
        Retained events: \(events.count)
        Dropped older events: \(droppedEventCount)
        Sessions represented: \(sessions.count)
        Events containing bounded body previews: \(eventsWithBodyPreviews)
        Capture fingerprint: \(fingerprint)

        Open manifest.json first. It maps every retained event to its provider/profile session,
        page URL, event URL, transport type, phase, status, timing, size, and JSON file path.

        Events contains every live event retained by ContextPort at the moment Save was pressed.
        Request and response body previews appear only when bounded previews were enabled and the
        payload was eligible for capture. Cookies, authorization headers, and unrestricted streaming
        bodies are not collected by the Live Interceptor.
        """
        try writer.add(
            data: Data(readme.utf8),
            path: "\(root)/README.txt"
        )

        try writer.finish()
        return archiveURL
    }

    private func installArchive(_ archiveURL: URL, for entry: LocalMemoryEntry) throws {
        let destination = DeveloperSourceMemoryArchiveBuilder.archiveURL(
            for: entry,
            fileManager: fileManager
        )
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

    private func memoryTitle(events: [DeveloperLiveNetworkEvent], generatedAt: Date) -> String {
        let providers = Array(Set(events.map { sessionProviderName($0.sessionTitle) })).sorted()
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
        return "\(providerLabel) Live Traffic \(formatter.string(from: generatedAt))"
    }

    private func memorySummary(
        events: [DeveloperLiveNetworkEvent],
        droppedEventCount: Int,
        generatedAt: Date,
        fingerprint: String
    ) -> String {
        let sessions = Array(Set(events.map(\.sessionTitle))).sorted()
        let sessionList = sessions.map { "- \($0)" }.joined(separator: "\n")
        let kindCounts = Dictionary(grouping: events, by: \.kind)
            .map { key, values in "- \(key): \(values.count)" }
            .sorted()
            .joined(separator: "\n")
        let previewCount = events.filter {
            $0.requestBodyPreview != nil || $0.responseBodyPreview != nil
        }.count

        return """
        # ContextPort Live Interceptor Capture

        Generated: \(ISO8601DateFormatter().string(from: generatedAt))

        This Memory contains one ZIP attachment with every live WKWebView event retained when Save was pressed.

        ## Capture Summary

        - Retained events: \(events.count)
        - Dropped older events: \(droppedEventCount)
        - Provider/profile sessions: \(sessions.count)
        - Events with bounded body previews: \(previewCount)
        - Capture fingerprint: \(fingerprint)

        ## Sessions

        \(sessionList)

        ## Event Types

        \(kindCounts)

        ## Analysis Note

        Open `manifest.json` first. Every retained event is also stored as its own JSON file so large captures can be inspected incrementally without loading the complete capture into memory.
        """
    }

    private func sessionProviderName(_ sessionTitle: String) -> String {
        sessionTitle.components(separatedBy: " • ").first ?? sessionTitle
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

private final class DeveloperLiveZIPWriter {
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
            throw DeveloperLiveMemoryArchiveError.archiveTooLarge
        }

        let pathData = Data(normalizedPath.utf8)
        let crc = DeveloperLiveCRC32.checksum(data)
        let size = UInt32(data.count)
        let dateParts = Self.dosDateParts(modifiedAt)
        let localOffset = currentOffset

        var header = Data()
        header.appendLiveLittleEndian(UInt32(0x04034B50))
        header.appendLiveLittleEndian(UInt16(20))
        header.appendLiveLittleEndian(UInt16(0x0800))
        header.appendLiveLittleEndian(UInt16(0))
        header.appendLiveLittleEndian(dateParts.time)
        header.appendLiveLittleEndian(dateParts.date)
        header.appendLiveLittleEndian(crc)
        header.appendLiveLittleEndian(size)
        header.appendLiveLittleEndian(size)
        header.appendLiveLittleEndian(UInt16(pathData.count))
        header.appendLiveLittleEndian(UInt16(0))
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
            throw DeveloperLiveMemoryArchiveError.tooManyFiles
        }

        let centralDirectoryOffset = currentOffset
        for entry in entries {
            var header = Data()
            header.appendLiveLittleEndian(UInt32(0x02014B50))
            header.appendLiveLittleEndian(UInt16(20))
            header.appendLiveLittleEndian(UInt16(20))
            header.appendLiveLittleEndian(UInt16(0x0800))
            header.appendLiveLittleEndian(UInt16(0))
            header.appendLiveLittleEndian(entry.dosTime)
            header.appendLiveLittleEndian(entry.dosDate)
            header.appendLiveLittleEndian(entry.crc32)
            header.appendLiveLittleEndian(entry.size)
            header.appendLiveLittleEndian(entry.size)
            header.appendLiveLittleEndian(UInt16(entry.pathData.count))
            header.appendLiveLittleEndian(UInt16(0))
            header.appendLiveLittleEndian(UInt16(0))
            header.appendLiveLittleEndian(UInt16(0))
            header.appendLiveLittleEndian(UInt16(0))
            header.appendLiveLittleEndian(UInt32(0))
            header.appendLiveLittleEndian(entry.localHeaderOffset)
            header.append(entry.pathData)
            try write(header)
        }

        let centralDirectorySize = currentOffset - centralDirectoryOffset
        let entryCount = UInt16(entries.count)

        var end = Data()
        end.appendLiveLittleEndian(UInt32(0x06054B50))
        end.appendLiveLittleEndian(UInt16(0))
        end.appendLiveLittleEndian(UInt16(0))
        end.appendLiveLittleEndian(entryCount)
        end.appendLiveLittleEndian(entryCount)
        end.appendLiveLittleEndian(centralDirectorySize)
        end.appendLiveLittleEndian(centralDirectoryOffset)
        end.appendLiveLittleEndian(UInt16(0))
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
            throw DeveloperLiveMemoryArchiveError.invalidPath
        }
        guard Data(normalized.utf8).count <= Int(UInt16.max) else {
            throw DeveloperLiveMemoryArchiveError.invalidPath
        }
        return normalized
    }

    private func write(_ data: Data) throws {
        let nextOffset = UInt64(currentOffset) + UInt64(data.count)
        guard nextOffset <= UInt64(UInt32.max) else {
            throw DeveloperLiveMemoryArchiveError.archiveTooLarge
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

private enum DeveloperLiveCRC32 {
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
    mutating func appendLiveLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(contentsOf: rawBuffer)
        }
    }
}
