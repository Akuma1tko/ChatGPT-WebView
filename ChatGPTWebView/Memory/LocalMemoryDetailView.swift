import SwiftUI

struct LocalMemoryDetailView: View {
    let entry: LocalMemoryEntry

    @State private var launchRequest: MemoryLaunchRequest?
    @State private var sourceArchiveShareItem: MemoryExportShareItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.title)
                    .font(.title2.weight(.bold))

                Button {
                    launchRequest = MemoryLaunchRequest(entries: [entry])
                } label: {
                    Label("Share Context", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                memoryInfo

                if let archiveURL = DeveloperSourceMemoryArchiveBuilder.existingArchiveURL(for: entry) {
                    developerSourceArchive(url: archiveURL)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Revision History")
                        .font(.headline)

                    ForEach(entry.orderedRevisions.reversed()) { revision in
                        NavigationLink {
                            LocalMemoryRevisionDetailView(entry: entry, revision: revision)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Revision \(revision.number)")
                                        .font(.body.weight(.semibold))
                                    Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(revision.source)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                if let messageCount = revision.messageCount {
                                    Text("\(messageCount) msgs")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $launchRequest) { request in
            MemoryLaunchSheet(entries: request.entries)
        }
        .sheet(item: $sourceArchiveShareItem) { item in
            MemoryExportShareSheet(url: item.url)
        }
    }

    private var memoryInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Revisions: \(entry.revisionCount)")
            Text("Created: \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
            Text("Updated: \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            Text("Project: \(entry.projectName)")
            Text("Latest source: \(entry.source)")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
    }

    private func developerSourceArchive(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Developer Sources ZIP")
                .font(.headline)

            Button {
                sourceArchiveShareItem = MemoryExportShareItem(url: url)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "archivebox.fill")
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share Source ZIP")
                            .font(.body.weight(.semibold))
                        Text(archiveSizeLabel(url: url))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private func archiveSizeLabel(url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return url.lastPathComponent
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return "\(url.lastPathComponent) · \(formatter.string(fromByteCount: Int64(fileSize)))"
    }
}
