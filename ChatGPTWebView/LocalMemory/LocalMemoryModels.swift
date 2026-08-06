import Foundation

struct LocalMemoryRevision: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let number: Int
    let createdAt: Date
    let source: String
    let pdfFilename: String?
    let markdownFilename: String?
    let messageCount: Int?
    let exportedAt: String?

    init(
        id: UUID = UUID(),
        number: Int,
        createdAt: Date = Date(),
        source: String,
        pdfFilename: String? = nil,
        markdownFilename: String? = nil,
        messageCount: Int? = nil,
        exportedAt: String? = nil
    ) {
        self.id = id
        self.number = max(number, 1)
        self.createdAt = createdAt
        self.source = source
        self.pdfFilename = pdfFilename
        self.markdownFilename = markdownFilename
        self.messageCount = messageCount
        self.exportedAt = exportedAt
    }
}

struct LocalMemoryEntry: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var projectName: String
    var title: String
    var content: String
    var source: String
    var tags: [String]
    var importance: Int
    var createdAt: Date
    var updatedAt: Date
    var pdfFilename: String?
    var markdownFilename: String?
    var messageCount: Int?
    var exportedAt: String?
    var attachmentFilenames: [String]
    var isFavorite: Bool
    var revisions: [LocalMemoryRevision]

    init(
        id: UUID = UUID(),
        projectName: String,
        title: String,
        content: String,
        source: String,
        tags: [String],
        importance: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        pdfFilename: String? = nil,
        markdownFilename: String? = nil,
        messageCount: Int? = nil,
        exportedAt: String? = nil,
        attachmentFilenames: [String] = [],
        isFavorite: Bool = false,
        revisions: [LocalMemoryRevision] = []
    ) {
        self.id = id
        self.projectName = projectName
        self.title = title
        self.content = content
        self.source = source
        self.tags = tags
        self.importance = min(max(importance, 1), 5)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pdfFilename = pdfFilename
        self.markdownFilename = markdownFilename
        self.messageCount = messageCount
        self.exportedAt = exportedAt
        self.attachmentFilenames = attachmentFilenames
        self.isFavorite = isFavorite
        self.revisions = revisions.isEmpty
            ? [
                LocalMemoryRevision(
                    id: id,
                    number: 1,
                    createdAt: createdAt,
                    source: source,
                    pdfFilename: pdfFilename,
                    markdownFilename: markdownFilename,
                    messageCount: messageCount,
                    exportedAt: exportedAt
                )
            ]
            : revisions.sorted { $0.number < $1.number }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.projectName = try container.decode(String.self, forKey: .projectName)
        self.title = try container.decode(String.self, forKey: .title)
        self.content = try container.decode(String.self, forKey: .content)
        self.source = try container.decode(String.self, forKey: .source)
        self.tags = try container.decode([String].self, forKey: .tags)
        self.importance = try container.decode(Int.self, forKey: .importance)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.pdfFilename = try container.decodeIfPresent(String.self, forKey: .pdfFilename)
        self.markdownFilename = try container.decodeIfPresent(String.self, forKey: .markdownFilename)
        self.messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount)
        self.exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt)
        self.attachmentFilenames = try container.decodeIfPresent([String].self, forKey: .attachmentFilenames) ?? []
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false

        let decodedRevisions = try container.decodeIfPresent([LocalMemoryRevision].self, forKey: .revisions) ?? []
        if decodedRevisions.isEmpty {
            self.revisions = [
                LocalMemoryRevision(
                    id: id,
                    number: 1,
                    createdAt: createdAt,
                    source: source,
                    pdfFilename: pdfFilename,
                    markdownFilename: markdownFilename,
                    messageCount: messageCount,
                    exportedAt: exportedAt
                )
            ]
        } else {
            self.revisions = decodedRevisions.sorted { $0.number < $1.number }
        }
    }

    var revisionCount: Int {
        revisions.count
    }

    var orderedRevisions: [LocalMemoryRevision] {
        revisions.sorted { $0.number < $1.number }
    }

    var latestRevision: LocalMemoryRevision? {
        orderedRevisions.last
    }
}

struct LocalMemorySaveResult: Sendable, Hashable {
    let entry: LocalMemoryEntry
    let totalCount: Int
    let message: String
}
