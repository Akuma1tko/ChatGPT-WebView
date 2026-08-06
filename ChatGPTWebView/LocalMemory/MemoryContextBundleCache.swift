import CryptoKit
import Foundation

struct MemoryContextBundleCache {
    private static let cacheVersion = 1
    private static let maximumBundleCount = 8
    private static let maximumCacheBytes: Int64 = 512 * 1_024 * 1_024

    private let fileManager: FileManager
    let root: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.root = caches.appendingPathComponent("ContextPortContextBundles", isDirectory: true)
    }

    func bundleFolder(for entries: [LocalMemoryEntry]) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(Self.fingerprint(for: entries), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func isUsableFile(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    func markUsed(_ folder: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
    }

    func prune(keeping currentFolder: URL) {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var records = folders.compactMap { folder -> CacheRecord? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return CacheRecord(url: folder, modifiedAt: modified, bytes: folderSize(folder))
        }

        var totalBytes = records.reduce(Int64(0)) { $0 + $1.bytes }
        records.sort { $0.modifiedAt < $1.modifiedAt }

        while records.count > Self.maximumBundleCount || totalBytes > Self.maximumCacheBytes {
            guard let index = records.firstIndex(where: { $0.url.standardizedFileURL != currentFolder.standardizedFileURL }) else {
                break
            }
            let record = records.remove(at: index)
            try? fileManager.removeItem(at: record.url)
            totalBytes -= record.bytes
        }
    }

    private func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func fingerprint(for entries: [LocalMemoryEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        var descriptor = "ContextPort Memory Bundle Cache v\(cacheVersion)\n"

        for (index, entry) in entries.enumerated() {
            descriptor += [
                "memory-index=\(index)",
                "memory-id=\(entry.id.uuidString)",
                "title=\(entry.title)",
                "project=\(entry.projectName)",
                "created=\(formatter.string(from: entry.createdAt))",
                "updated=\(formatter.string(from: entry.updatedAt))",
                "revision-count=\(entry.revisionCount)"
            ].joined(separator: "\n")
            descriptor += "\n"

            for revision in entry.orderedRevisions {
                descriptor += [
                    "revision-id=\(revision.id.uuidString)",
                    "revision-number=\(revision.number)",
                    "revision-created=\(formatter.string(from: revision.createdAt))",
                    "revision-source=\(revision.source)",
                    "revision-messages=\(revision.messageCount.map { String($0) } ?? "unknown")",
                    "revision-exported=\(revision.exportedAt ?? "")",
                    "revision-pdf=\(revision.pdfFilename ?? "")",
                    "revision-markdown=\(revision.markdownFilename ?? "")"
                ].joined(separator: "\n")
                descriptor += "\n"
            }
        }

        let digest = SHA256.hash(data: Data(descriptor.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct CacheRecord {
    let url: URL
    let modifiedAt: Date
    let bytes: Int64
}
