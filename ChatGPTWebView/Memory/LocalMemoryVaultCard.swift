import SwiftUI
import UIKit

struct LocalMemoryVaultCard: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext.fill")
                    .foregroundColor(.accentColor)
                Text("Local PDF Context Memory")
                    .font(.headline)
            }

            Text("Saved chats are exported as PDFs from the ChatGPT tab. No manual memory text entry is used here.")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                LocalMemoryMetric(title: "Saved PDFs", value: "\(appModel.localMemoryEntries.count)")
                LocalMemoryMetric(title: "Available", value: appModel.localMemoryEntries.isEmpty ? "No" : "Yes")
            }

            HStack(spacing: 10) {
                Button {
                    appModel.reloadLocalMemory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appModel.renderLocalProjectContext()
                    UIPasteboard.general.string = appModel.localRenderedContext
                    appModel.statusMessage = "Copied rendered local PDF context index."
                } label: {
                    Label("Copy Index", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.localMemoryEntries.isEmpty)
            }

            if appModel.localMemoryEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No saved PDF contexts yet.")
                        .font(.subheadline.weight(.semibold))
                    Text("Open the ChatGPT tab, then tap Save Context near Stop to export the current chat as a local PDF.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved PDF Contexts")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    ForEach(appModel.localMemoryEntries) { entry in
                        NavigationLink {
                            LocalMemoryDetailView(entry: entry)
                                .environmentObject(appModel)
                        } label: {
                            LocalMemoryResultRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LocalMemoryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LocalMemoryResultRow: View {
    let entry: LocalMemoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.richtext")
                    .foregroundColor(.accentColor)
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            Text(entry.source)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack {
                if let pdfFilename = entry.pdfFilename {
                    Text(pdfFilename)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(entry.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
