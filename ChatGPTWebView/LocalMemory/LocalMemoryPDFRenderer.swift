import Foundation
import UIKit

enum LocalMemoryPDFRenderer {
    static func render(entry: LocalMemoryEntry, to url: URL) throws {
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 48
        let bodyRect = pageBounds.insetBy(dx: margin, dy: margin + 34)
        let chunks = chunkText(entry.content, maxCharacters: 2600)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: entry.title,
            kCGPDFContextAuthor as String: "ChatGPTWebView Local Device Memory Vault",
            kCGPDFContextCreator as String: "ChatGPTWebView"
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format)
        try renderer.writePDF(to: url) { context in
            for (index, chunk) in chunks.enumerated() {
                context.beginPage()
                drawHeader(entry: entry, page: index + 1, pageCount: chunks.count, pageBounds: pageBounds, margin: margin)
                drawBody(text: chunk, in: bodyRect)
            }
        }
    }

    private static func drawHeader(entry: LocalMemoryEntry, page: Int, pageCount: Int, pageBounds: CGRect, margin: CGFloat) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 15),
            .foregroundColor: UIColor.label
        ]
        let metaAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.secondaryLabel
        ]

        let title = entry.title as NSString
        title.draw(
            in: CGRect(x: margin, y: 28, width: pageBounds.width - margin * 2, height: 22),
            withAttributes: titleAttributes
        )

        let meta = "Project: \(entry.projectName)   Source: \(entry.source)   Importance: \(entry.importance)/5   Page \(page) of \(pageCount)" as NSString
        meta.draw(
            in: CGRect(x: margin, y: 52, width: pageBounds.width - margin * 2, height: 16),
            withAttributes: metaAttributes
        )

        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: 74))
        path.addLine(to: CGPoint(x: pageBounds.width - margin, y: 74))
        UIColor.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawBody(text: String, in rect: CGRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 8

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    private static func chunkText(_ text: String, maxCharacters: Int) -> [String] {
        guard !text.isEmpty else {
            return [""]
        }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let roughEnd = text.index(start, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            var end = roughEnd

            if roughEnd < text.endIndex,
               let newlineRange = text[start..<roughEnd].range(of: "\n", options: .backwards),
               text.distance(from: start, to: newlineRange.lowerBound) > maxCharacters / 2 {
                end = newlineRange.lowerBound
            }

            chunks.append(String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end

            while start < text.endIndex, text[start].isWhitespace || text[start].isNewline {
                start = text.index(after: start)
            }
        }

        return chunks.filter { !$0.isEmpty }
    }
}
