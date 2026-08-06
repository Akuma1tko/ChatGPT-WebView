import CoreGraphics
import Foundation

final class MemoryContextPDFCompiler {
    private let fileManager: FileManager
    private let store: LocalMemoryStore

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.store = LocalMemoryStore(fileManager: fileManager)
    }

    func compile(entries: [LocalMemoryEntry], to destination: URL) throws -> Bool {
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".pdf-\(UUID().uuidString).tmp")
        try? fileManager.removeItem(at: temporaryURL)

        guard let consumer = CGDataConsumer(url: temporaryURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw MemoryContextBundleError.couldNotBuildPDF
        }

        var pageCount = 0
        for entry in entries {
            for revision in entry.orderedRevisions {
                if let sourceURL = store.pdfURL(for: revision) {
                    let appended = appendPages(from: sourceURL, to: context)
                    if appended > 0 {
                        pageCount += appended
                        continue
                    }
                }

                guard let markdown = store.markdownText(for: revision, in: entry) else {
                    continue
                }

                let fallbackURL = destination.deletingLastPathComponent()
                    .appendingPathComponent(".fallback-\(revision.id.uuidString).pdf")
                let fallbackEntry = LocalMemoryEntry(
                    projectName: entry.projectName,
                    title: "\(entry.title) · Revision \(revision.number)",
                    content: markdown,
                    source: revision.source,
                    tags: entry.tags,
                    importance: entry.importance,
                    createdAt: revision.createdAt,
                    updatedAt: revision.createdAt,
                    messageCount: revision.messageCount,
                    exportedAt: revision.exportedAt
                )
                try LocalMemoryPDFRenderer.render(entry: fallbackEntry, to: fallbackURL)
                pageCount += appendPages(from: fallbackURL, to: context)
                try? fileManager.removeItem(at: fallbackURL)
            }
        }

        context.closePDF()

        guard pageCount > 0 else {
            try? fileManager.removeItem(at: temporaryURL)
            return false
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return true
    }

    private func appendPages(from sourceURL: URL, to context: CGContext) -> Int {
        guard let document = CGPDFDocument(sourceURL as CFURL), document.numberOfPages > 0 else {
            return 0
        }

        var appended = 0
        for pageIndex in 1...document.numberOfPages {
            guard let page = document.page(at: pageIndex) else { continue }
            var mediaBox = page.getBoxRect(.mediaBox)
            if mediaBox.isEmpty {
                mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            }

            let mediaBoxData = NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
            let pageInfo = [kCGPDFContextMediaBox as String: mediaBoxData] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.saveGState()
            let transform = page.getDrawingTransform(
                .mediaBox,
                rect: mediaBox,
                rotate: 0,
                preserveAspectRatio: true
            )
            context.concatenate(transform)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
            appended += 1
        }

        return appended
    }
}
