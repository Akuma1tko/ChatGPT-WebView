import PDFKit
import SwiftUI
import UIKit

private enum RevisionPreviewMode: String, CaseIterable, Identifiable {
    case pdf
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf:
            return "PDF"
        case .markdown:
            return "Markdown"
        }
    }
}

struct LocalMemoryRevisionDetailView: View {
    @EnvironmentObject private var appModel: AppModel

    let entry: LocalMemoryEntry
    let revision: LocalMemoryRevision

    @State private var isExporting = false
    @State private var exportShareItem: MemoryExportShareItem?
    @State private var selectedPreview: RevisionPreviewMode
    @State private var markdownText: String?
    @State private var isLoadingMarkdown = false

    private let store = LocalMemoryStore()

    init(entry: LocalMemoryEntry, revision: LocalMemoryRevision) {
        self.entry = entry
        self.revision = revision
        let initialPreview: RevisionPreviewMode = LocalMemoryStore().pdfURL(for: revision) == nil
            ? .markdown
            : .pdf
        self._selectedPreview = State(initialValue: initialPreview)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.title)
                    .font(.title3.weight(.bold))

                Button {
                    exportRevision()
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Preparing Revision ZIP")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Export Revision", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || !hasExportableFiles)

                revisionInfo

                if availablePreviewModes.count > 1 {
                    Picker("Preview", selection: $selectedPreview) {
                        ForEach(availablePreviewModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                previewContent
            }
            .padding()
        }
        .navigationTitle("Revision \(revision.number)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportShareItem) { item in
            MemoryExportShareSheet(url: item.url)
        }
        .task(id: selectedPreview) {
            await loadMarkdownIfNeeded()
        }
    }

    private var pdfURL: URL? {
        store.pdfURL(for: revision)
    }

    private var hasMarkdown: Bool {
        store.markdownURL(for: revision) != nil
            || (revision.number == entry.latestRevision?.number && !entry.content.isEmpty)
    }

    private var availablePreviewModes: [RevisionPreviewMode] {
        RevisionPreviewMode.allCases.filter { mode in
            switch mode {
            case .pdf:
                return pdfURL != nil
            case .markdown:
                return hasMarkdown
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch selectedPreview {
        case .pdf:
            if let pdfURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PDF")
                        .font(.headline)
                    LocalPDFPreview(url: pdfURL)
                        .frame(height: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                }
            } else {
                unavailablePreview("Revision PDF is unavailable on this device.")
            }
        case .markdown:
            VStack(alignment: .leading, spacing: 8) {
                Text("Markdown")
                    .font(.headline)

                if isLoadingMarkdown {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Markdown")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } else if let markdownText {
                    Text(markdownText)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    unavailablePreview("Revision Markdown is unavailable on this device.")
                }
            }
        }
    }

    private var hasExportableFiles: Bool {
        pdfURL != nil || store.markdownURL(for: revision) != nil
    }

    private var revisionInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved: \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
            if let messageCount = revision.messageCount {
                Text("Messages: \(messageCount)")
            }
            Text("Source: \(revision.source)")
            if let pdfFilename = revision.pdfFilename {
                Text("PDF: \(pdfFilename)")
            }
            if let markdownFilename = revision.markdownFilename {
                Text("Markdown: \(markdownFilename)")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func unavailablePreview(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundColor(.secondary)
    }

    private func loadMarkdownIfNeeded() async {
        guard selectedPreview == .markdown, markdownText == nil, !isLoadingMarkdown else {
            return
        }

        isLoadingMarkdown = true
        let memory = entry
        let selectedRevision = revision
        let loadedText = await Task.detached(priority: .userInitiated) {
            LocalMemoryStore().markdownText(for: selectedRevision, in: memory)
        }.value
        markdownText = loadedText
        isLoadingMarkdown = false
    }

    private func exportRevision() {
        guard !isExporting, hasExportableFiles else { return }
        let memory = entry
        let selectedRevision = revision

        isExporting = true
        appModel.statusMessage = "Preparing Revision \(revision.number) ZIP..."

        Task { @MainActor in
            defer { isExporting = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try MemoryExportArchiveBuilder().exportRevision(
                        entry: memory,
                        revision: selectedRevision
                    )
                }.value
                exportShareItem = MemoryExportShareItem(url: url)
                appModel.statusMessage = "Revision \(revision.number) ZIP is ready to share or save to Files."
            } catch {
                appModel.statusMessage = "Revision export failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct LocalPDFPreview: UIViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        loadDocumentIfNeeded(into: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        loadDocumentIfNeeded(into: uiView, coordinator: context.coordinator)
    }

    private func loadDocumentIfNeeded(into view: PDFView, coordinator: Coordinator) {
        let normalizedURL = url.standardizedFileURL
        guard coordinator.loadedURL != normalizedURL else { return }
        coordinator.loadedURL = normalizedURL
        view.document = PDFDocument(url: normalizedURL)
    }
}
