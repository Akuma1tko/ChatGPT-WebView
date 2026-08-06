import SwiftUI
import UniformTypeIdentifiers

struct MemoryTestView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var memoryWriteActivity = LocalMemoryWriteActivity.shared

    @State private var selectedSection = MemorySection.all
    @State private var isSelecting = false
    @State private var isExportingMemories = false
    @State private var isImporting = false
    @State private var isShowingImportPicker = false
    @State private var selectedEntryIDs = Set<UUID>()
    @State private var launchRequest: MemoryLaunchRequest?
    @State private var exportShareItem: MemoryExportShareItem?

    private let store = LocalMemoryStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Memory Section", selection: $selectedSection) {
                    ForEach(MemorySection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if memoryWriteActivity.isWriting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.red)

                        Text("Please wait. Something is still being saved to Memory.")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.red)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Color.red.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Please wait. Something is still being saved to Memory.")
                }

                List {
                    if displayedEntries.isEmpty {
                        Text(emptyMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(displayedEntries) { entry in
                            memoryRow(entry)
                        }
                        .onDelete(perform: deleteSavedChats)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            exportMemories()
                        } label: {
                            Label(exportMenuTitle, systemImage: "square.and.arrow.up")
                        }
                        .disabled(appModel.localMemoryEntries.isEmpty)

                        Button {
                            isShowingImportPicker = true
                        } label: {
                            Label("Import Memory ZIP", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        if isExportingMemories || isImporting {
                            ProgressView()
                        } else {
                            Image(systemName: "archivebox")
                        }
                    }
                    .disabled(
                        isExportingMemories
                        || isImporting
                        || memoryWriteActivity.isWriting
                    )
                    .accessibilityLabel("Memory import and export")

                    Button {
                        appModel.reloadLocalMemory()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh saved chats")

                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedEntryIDs.removeAll()
                        }
                    }
                    .disabled(
                        !isSelecting
                        && (
                            displayedEntries.isEmpty
                            || memoryWriteActivity.isWriting
                        )
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting, !selectedEntryIDs.isEmpty {
                    Button {
                        let entries = appModel.localMemoryEntries.filter { selectedEntryIDs.contains($0.id) }
                        launchRequest = MemoryLaunchRequest(entries: entries)
                    } label: {
                        Text("Share Context · \(selectedEntryIDs.count)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .sheet(item: $launchRequest) { request in
            MemoryLaunchSheet(entries: request.entries) {
                isSelecting = false
                selectedEntryIDs.removeAll()
            }
        }
        .sheet(item: $exportShareItem) { item in
            MemoryExportShareSheet(url: item.url)
        }
        .fileImporter(
            isPresented: $isShowingImportPicker,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importMemoryArchive(url)
            case .failure(let error):
                appModel.statusMessage = "Memory import failed: \(error.localizedDescription)"
            }
        }
        .onAppear {
            appModel.reloadLocalMemory()
        }
        .onChange(of: selectedSection) { _ in
            selectedEntryIDs.removeAll()
        }
    }

    private var displayedEntries: [LocalMemoryEntry] {
        switch selectedSection {
        case .all:
            return appModel.localMemoryEntries
        case .favorites:
            return appModel.localMemoryEntries.filter(\.isFavorite)
        }
    }

    private var exportEntries: [LocalMemoryEntry] {
        guard !selectedEntryIDs.isEmpty else {
            return appModel.localMemoryEntries
        }

        return appModel.localMemoryEntries.filter { selectedEntryIDs.contains($0.id) }
    }

    private var exportMenuTitle: String {
        guard !selectedEntryIDs.isEmpty else {
            return "Export All Memories"
        }

        return "Export Selected Memories · \(selectedEntryIDs.count)"
    }

    private var emptyMessage: String {
        switch selectedSection {
        case .all:
            return "No saved chats yet. Open an AI tab and tap Save Context."
        case .favorites:
            return "No favorite memories yet. Tap the star beside a saved Memory to add it here."
        }
    }

    @ViewBuilder
    private func memoryRow(_ entry: LocalMemoryEntry) -> some View {
        if isSelecting {
            HStack(spacing: 10) {
                Button {
                    toggleSelection(entry)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedEntryIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedEntryIDs.contains(entry.id) ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .lineLimit(2)
                            Text(revisionLabel(for: entry))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 8) {
                NavigationLink {
                    LocalMemoryDetailView(entry: entry)
                        .environmentObject(appModel)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .lineLimit(2)
                        Text(revisionLabel(for: entry))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    toggleFavorite(entry)
                } label: {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                        .foregroundColor(entry.isFavorite ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
    }

    private func revisionLabel(for entry: LocalMemoryEntry) -> String {
        let noun = entry.revisionCount == 1 ? "revision" : "revisions"
        return "\(entry.revisionCount) \(noun)"
    }

    private func exportMemories() {
        guard !isExportingMemories else { return }
        let entries = exportEntries
        guard !entries.isEmpty else { return }
        let isSelectedExport = !selectedEntryIDs.isEmpty

        isExportingMemories = true
        if isSelectedExport {
            appModel.statusMessage = "Preparing ZIP export for \(entries.count) selected Memories..."
        } else {
            appModel.statusMessage = "Preparing ZIP export for all Memories..."
        }

        Task { @MainActor in
            defer { isExportingMemories = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try MemoryExportArchiveBuilder().exportAll(entries: entries)
                }.value
                exportShareItem = MemoryExportShareItem(url: url)
                if isSelectedExport {
                    appModel.statusMessage = "Selected Memory ZIP export is ready to share or save to Files."
                } else {
                    appModel.statusMessage = "Memory ZIP export is ready to share or save to Files."
                }
            } catch {
                appModel.statusMessage = "Memory export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importMemoryArchive(_ url: URL) {
        guard !isImporting else { return }
        isImporting = true
        appModel.statusMessage = "Importing ContextPort Memory ZIP..."

        Task { @MainActor in
            defer { isImporting = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let isAccessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if isAccessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    return try MemoryImportArchiveReader().importArchive(at: url)
                }.value
                appModel.reloadLocalMemory()
                appModel.statusMessage = result.message
            } catch {
                appModel.statusMessage = "Memory import failed: \(error.localizedDescription)"
            }
        }
    }

    private func toggleSelection(_ entry: LocalMemoryEntry) {
        if selectedEntryIDs.contains(entry.id) {
            selectedEntryIDs.remove(entry.id)
        } else {
            selectedEntryIDs.insert(entry.id)
        }
    }

    private func toggleFavorite(_ entry: LocalMemoryEntry) {
        do {
            try store.toggleFavorite(for: entry)
            appModel.reloadLocalMemory()
        } catch {
            appModel.statusMessage = "Could not update favorite: \(error.localizedDescription)"
        }
    }

    private func deleteSavedChats(at offsets: IndexSet) {
        let entries = displayedEntries
        for offset in offsets {
            guard entries.indices.contains(offset) else { continue }
            selectedEntryIDs.remove(entries[offset].id)
            DeveloperSourceMemoryArchiveBuilder.deleteArchive(for: entries[offset])
            try? store.deleteEntry(entries[offset])
        }
        appModel.reloadLocalMemory()
        appModel.statusMessage = "Deleted Memory and its revisions."
    }
}

private enum MemorySection: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .favorites:
            return "Favorites"
        }
    }
}
