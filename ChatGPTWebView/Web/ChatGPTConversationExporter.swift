import Foundation
import UIKit
import WebKit

struct ChatConversationExportResult {
    let title: String
    let markdown: String
    let messageCount: Int
    let sourceURL: String
    let exportedAt: String
    let pdfData: Data
    let extractionHealth: ProviderExtractionHealthReport
}

enum ChatConversationExportError: LocalizedError {
    case invalidPayload
    case unsupportedConversationPage
    case securityInterstitialDetected
    case noMessagesFound
    case invalidConversationStructure
    case chatGPTConversationMapUnavailable
    case providerCaptureRequired(String)
    case providerUIChanged(String)
    case cannotCreatePDF

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "The AI page did not return a readable export payload."
        case .unsupportedConversationPage:
            return "ContextPort could not verify that this is a supported AI conversation page. Open a conversation and try again."
        case .securityInterstitialDetected:
            return "ContextPort detected a security or bot-check interstitial instead of a readable conversation. Complete the check, return to the conversation, and try Save Context again."
        case .noMessagesFound:
            return "No positively identified conversation messages were found. The AI page may have changed or may not be a conversation."
        case .invalidConversationStructure:
            return "ContextPort found conversation content but could not verify both a user turn and an AI response. Nothing was saved."
        case .chatGPTConversationMapUnavailable:
            return "ContextPort could not recover ChatGPT's complete active conversation branch from the current provider conversation transport. Nothing was saved because a DOM-only snapshot may omit older or non-materialized turns. Refresh the conversation and try Save Context again."
        case .providerCaptureRequired(let providerName):
            return "Save Context for \(providerName) is intentionally disabled until ContextPort captures and verifies that provider's real conversation UI markers. Enable Developer Mode, open a short \(providerName) conversation, then save the loaded Sources to Memory for selector review."
        case .providerUIChanged(let message):
            return message
        case .cannotCreatePDF:
            return "The Markdown export was created, but the PDF renderer could not create a PDF."
        }
    }
}

private struct ChatConversationExportTurn: Decodable {
    let role: String
    let content: String
}

private struct ChatConversationExportPayload: Decodable {
    let title: String
    let turns: [ChatConversationExportTurn]
    let sourceURL: String
    let exportedAt: String
    let error: String?
    let diagnostics: ProviderExtractionDiagnostics
}

private struct ValidatedConversationTurn {
    enum Role {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

@MainActor
final class ChatConversationExporter {
    static func exportConversation(from webView: WKWebView) async throws -> ChatConversationExportResult {
        try await exportConversation(
            from: webView,
            provider: AIProviderID.chatGPT.provider
        )
    }

    static func exportConversation(
        from webView: WKWebView,
        provider: AIProvider
    ) async throws -> ChatConversationExportResult {
        guard provider.isAuthenticatedContentURL(webView.url) else {
            throw ChatConversationExportError.unsupportedConversationPage
        }

        let json: String
        if provider.id == .chatGPT {
            let mapCapture = try await ChatGPTConversationMapCapture.capture(from: webView)
            if mapCapture.isConversationRoute {
                guard let payloadJSON = mapCapture.payloadJSON else {
                    throw ChatConversationExportError.invalidPayload
                }
                json = payloadJSON
            } else {
                let raw = try await evaluateJavaScript(
                    extractionJavaScript(provider: provider),
                    in: webView
                )
                guard let payloadJSON = raw as? String else {
                    throw ChatConversationExportError.invalidPayload
                }
                json = payloadJSON
            }
        } else {
            let raw = try await evaluateJavaScript(
                extractionJavaScript(provider: provider),
                in: webView
            )
            guard let payloadJSON = raw as? String else {
                throw ChatConversationExportError.invalidPayload
            }
            json = payloadJSON
        }

        guard let data = json.data(using: .utf8) else {
            throw ChatConversationExportError.invalidPayload
        }

        let payload = try JSONDecoder().decode(ChatConversationExportPayload.self, from: data)
        if payload.error == "provider-capture-required" {
            throw ChatConversationExportError.providerCaptureRequired(provider.displayName)
        }
        if payload.error == "chatgpt-map-unavailable" || payload.error == "chatgpt-map-incomplete" {
            throw ChatConversationExportError.chatGPTConversationMapUnavailable
        }

        let turns = payload.turns.compactMap(validateTurn)
        let userTurnCount = turns.filter { $0.role == .user }.count
        let assistantTurnCount = turns.filter { $0.role == .assistant }.count
        let healthReport = ProviderExtractionHealthMonitor.evaluate(
            provider: provider,
            diagnostics: payload.diagnostics,
            userTurnCount: userTurnCount,
            assistantTurnCount: assistantTurnCount
        )

        ProviderExtractionHealthAlertPresenter.presentIfNeeded(healthReport)

        if healthReport.state == .unsafe {
            if payload.error == "security-interstitial" || healthReport.challengeDetected {
                throw ChatConversationExportError.securityInterstitialDetected
            }
            throw ChatConversationExportError.providerUIChanged(healthReport.failureDescription)
        }

        guard !turns.isEmpty else {
            throw ChatConversationExportError.noMessagesFound
        }

        guard userTurnCount > 0, assistantTurnCount > 0 else {
            throw ChatConversationExportError.invalidConversationStructure
        }

        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let exportedAt = payload.exportedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = payload.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = makeMarkdown(
            title: title.isEmpty ? "\(provider.displayName) Conversation" : title,
            turns: turns,
            sourceURL: sourceURL,
            exportedAt: exportedAt,
            provider: provider
        )

        let messageCount = turns.count
        let pdfData = try makePDFData(
            title: title,
            markdown: markdown,
            sourceURL: sourceURL,
            exportedAt: exportedAt,
            messageCount: messageCount
        )
        return ChatConversationExportResult(
            title: title.isEmpty ? "\(provider.displayName) Conversation" : title,
            markdown: markdown,
            messageCount: messageCount,
            sourceURL: sourceURL,
            exportedAt: exportedAt,
            pdfData: pdfData,
            extractionHealth: healthReport
        )
    }

    private static func validateTurn(_ turn: ChatConversationExportTurn) -> ValidatedConversationTurn? {
        let role: ValidatedConversationTurn.Role
        switch turn.role.lowercased() {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }

        let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 5, !containsSecurityInterstitialMarker(content) else {
            return nil
        }
        return ValidatedConversationTurn(role: role, content: content)
    }

    private static func containsSecurityInterstitialMarker(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("__cf$cv$params")
            || lower.contains("/cdn-cgi/challenge-platform/")
            || lower.contains("cf-turnstile")
            || lower.contains("challenge-platform/scripts")
    }

    private static func makeMarkdown(
        title: String,
        turns: [ValidatedConversationTurn],
        sourceURL: String,
        exportedAt: String,
        provider: AIProvider
    ) -> String {
        var lines = [
            "# \(title)",
            "",
            "**Exported:** \(exportedAt)",
            "**Source:** \(sourceURL)",
            "**Messages:** \(turns.count)",
            "",
            "---",
            ""
        ]

        for turn in turns {
            let sender = turn.role == .user ? "You" : provider.displayName
            lines.append("### **\(sender)**")
            lines.append("")
            lines.append(turn.content)
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: ChatConversationExportError.invalidPayload)
                }
            }
        }
    }

    private static func makePDFData(
        title: String,
        markdown: String,
        sourceURL: String,
        exportedAt: String,
        messageCount: Int
    ) throws -> Data {
        let html = """
        <!doctype html><html><head><meta charset=\"utf-8\"><style>
        body{font-family:-apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.45;color:#111}h1{font-size:22px;margin-bottom:6px}.meta{color:#555;font-size:10px;margin-bottom:18px;word-break:break-word}pre{white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:10px}
        </style></head><body><h1>\(escapeHTML(title))</h1><div class=\"meta\">Exported: \(escapeHTML(exportedAt))<br>Messages: \(messageCount)<br>Source: \(escapeHTML(sourceURL))</div><pre>\(escapeHTML(markdown))</pre></body></html>
        """
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        renderer.setValue(pageRect, forKey: "paperRect")
        renderer.setValue(pageRect.insetBy(dx: 36, dy: 36), forKey: "printableRect")
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: 0))
        guard renderer.numberOfPages > 0 else {
            throw ChatConversationExportError.cannotCreatePDF
        }

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, .zero, nil)
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func extractionJavaScript(provider: AIProvider) -> String {
        ProviderConversationExtractionScript.make(provider: provider)
    }

}

typealias ChatGPTConversationExporter = ChatConversationExporter

@MainActor
extension ChatGPTWebViewStore {
    func exportCurrentConversation() async throws -> ChatConversationExportResult {
        try await ChatConversationExporter.exportConversation(from: webView, provider: provider)
    }
}
