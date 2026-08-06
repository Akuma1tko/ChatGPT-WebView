import Foundation
import SwiftUI
import WebKit

struct DeveloperLiveInterceptorView: View {
    let isActive: Bool

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var profileSessionPool: ChatGPTProfileSessionPool
    @ObservedObject private var memoryWriteActivity = LocalMemoryWriteActivity.shared
    @StateObject private var model = DeveloperLiveInterceptorModel()
    @State private var searchText = ""
    @State private var selectedKind = DeveloperLiveEventKindFilter.all
    @State private var selectedSession = DeveloperLiveSessionFilter.all
    @State private var captureBodyPreviews = false
    @State private var isSavingToMemory = false
    @State private var lastSavedSnapshotGeneration: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        if model.isCapturing || isSavingToMemory {
                            ProgressView()
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.status)
                                .font(.footnote)
                                .foregroundColor(.secondary)

                            if model.droppedEventCount > 0 {
                                Text("Dropped \(model.droppedEventCount) older event\(model.droppedEventCount == 1 ? "" : "s") to stay within the live capture limit.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Button {
                        if model.isCapturing {
                            model.stop()
                        } else {
                            model.start(
                                sessions: profileSessionPool.developerSourceSessions(),
                                captureBodyPreviews: captureBodyPreviews
                            )
                        }
                    } label: {
                        Label(
                            model.isCapturing ? "Stop Live Capture" : "Start Live Capture",
                            systemImage: model.isCapturing ? "stop.circle.fill" : "record.circle"
                        )
                    }
                    .disabled(isSavingToMemory)

                    Toggle("Bounded Body Previews", isOn: $captureBodyPreviews)
                        .disabled(model.isCapturing || isSavingToMemory)

                    Button {
                        saveEverythingDiscoveredToMemory()
                    } label: {
                        Label(
                            isCurrentSnapshotSaved
                                ? "Saved Everything to Memory"
                                : "Save Everything Discovered to Memory",
                            systemImage: isCurrentSnapshotSaved
                                ? "checkmark.circle.fill"
                                : "archivebox.fill"
                        )
                    }
                    .disabled(
                        model.events.isEmpty
                        || isSavingToMemory
                        || isCurrentSnapshotSaved
                    )

                    Button(role: .destructive) {
                        model.clear()
                    } label: {
                        Label("Clear Live Log", systemImage: "trash")
                    }
                    .disabled(model.events.isEmpty || isSavingToMemory)
                } header: {
                    Text("Live Interceptor")
                } footer: {
                    Text("Live capture installs a bounded JavaScript bridge in each currently loaded provider WKWebView. It watches fetch, XMLHttpRequest, WebSocket, EventSource, sendBeacon, navigation, and browser resource timing. Cookies, authorization headers, and complete streaming bodies are never collected. Body previews are off by default and remain capped when enabled. Capture continues while you switch back to the AI tab until you press Stop. Save Everything archives the complete retained log at the moment the button is pressed, regardless of the current search or filters.")
                }

                Section("Filters") {
                    Picker("Event Type", selection: $selectedKind) {
                        ForEach(DeveloperLiveEventKindFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }

                    Picker("Session", selection: $selectedSession) {
                        Text("All Sessions").tag(DeveloperLiveSessionFilter.all)
                        ForEach(model.sessionTitles, id: \.self) { title in
                            Text(title).tag(DeveloperLiveSessionFilter.session(title))
                        }
                    }
                }

                Section("Events") {
                    if visibleEvents.isEmpty {
                        Text(emptyStateMessage)
                            .foregroundColor(.secondary)
                    }

                    ForEach(visibleEvents) { event in
                        NavigationLink {
                            DeveloperLiveEventDetailView(event: event)
                        } label: {
                            DeveloperLiveEventRow(event: event)
                        }
                    }
                }
            }
            .navigationTitle("Live Interceptor")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search URL, method, status, or session")
            .onChange(of: captureBodyPreviews) { enabled in
                guard model.isCapturing else { return }
                model.updateBodyPreviewCapture(enabled)
            }
            .onDisappear {
                // Intentionally do not stop here. The user must be able to return to the
                // provider tab while capture continues.
            }
        }
    }

    private var isCurrentSnapshotSaved: Bool {
        guard !model.events.isEmpty,
              let lastSavedSnapshotGeneration else {
            return false
        }
        return lastSavedSnapshotGeneration == model.snapshotGeneration
    }

    private var visibleEvents: [DeveloperLiveNetworkEvent] {
        let normalizedSearch = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return model.events.reversed().filter { event in
            guard selectedKind.matches(event) else { return false }
            guard selectedSession.matches(event) else { return false }
            guard !normalizedSearch.isEmpty else { return true }
            return event.searchText.contains(normalizedSearch)
        }
    }

    private var emptyStateMessage: String {
        if model.isCapturing {
            return "Listening for live WKWebView traffic. Return to an AI tab and use the provider normally."
        }
        if model.events.isEmpty {
            return "No live events captured. Press Start Live Capture, then return to an AI tab."
        }
        return "No captured event matches the current filters."
    }

    private func saveEverythingDiscoveredToMemory() {
        guard !isSavingToMemory, !model.events.isEmpty else { return }

        let snapshot = model.events
        let droppedEventCount = model.droppedEventCount
        let snapshotGeneration = model.snapshotGeneration
        isSavingToMemory = true
        memoryWriteActivity.begin()
        appModel.statusMessage = "Packaging all \(snapshot.count) retained live events into one Memory ZIP..."

        Task { @MainActor in
            defer {
                isSavingToMemory = false
                memoryWriteActivity.end()
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DeveloperLiveInterceptorMemoryArchiveBuilder().saveToMemory(
                        events: snapshot,
                        droppedEventCount: droppedEventCount
                    )
                }.value
                lastSavedSnapshotGeneration = snapshotGeneration
                appModel.reloadLocalMemory()
                appModel.statusMessage = result.message
            } catch {
                appModel.reloadLocalMemory()
                appModel.statusMessage = "Live Interceptor ZIP save failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct DeveloperLiveEventRow: View {
    let event: DeveloperLiveNetworkEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.primaryLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let status = event.status {
                    Text("\(status)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundColor(status >= 400 ? .red : .secondary)
                }
            }

            Text(event.displayURL)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(event.sessionTitle)
                    .lineLimit(1)

                if let duration = event.durationMilliseconds {
                    Text("\(duration.formatted(.number.precision(.fractionLength(0)))) ms")
                }

                Text(event.timestamp.formatted(date: .omitted, time: .standard))
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct DeveloperLiveEventDetailView: View {
    let event: DeveloperLiveNetworkEvent

    var body: some View {
        List {
            Section("Event") {
                LabeledContent("Session", value: event.sessionTitle)
                LabeledContent("Type", value: event.kind)
                LabeledContent("Phase", value: event.phase)
                LabeledContent("Time", value: event.timestamp.formatted(date: .abbreviated, time: .standard))

                if let method = event.method {
                    LabeledContent("Method", value: method)
                }
                if let status = event.status {
                    LabeledContent("Status", value: "\(status)")
                }
                if let duration = event.durationMilliseconds {
                    LabeledContent(
                        "Duration",
                        value: "\(duration.formatted(.number.precision(.fractionLength(1)))) ms"
                    )
                }
                if let mimeType = event.mimeType {
                    LabeledContent("MIME Type", value: mimeType)
                }
                if let transferSize = event.transferSize {
                    LabeledContent(
                        "Transfer Size",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(transferSize),
                            countStyle: .file
                        )
                    )
                }
            }

            Section("URL") {
                Text(event.displayURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            if let requestBodyPreview = event.requestBodyPreview {
                Section("Request Body Preview") {
                    Text(requestBodyPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let responseBodyPreview = event.responseBodyPreview {
                Section("Response Body Preview") {
                    Text(responseBodyPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let detail = event.detail {
                Section("Detail") {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(event.primaryLabel)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum DeveloperLiveEventKindFilter: String, CaseIterable, Identifiable {
    case all
    case fetch
    case xhr
    case socket
    case resource
    case navigation
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .fetch: return "Fetch"
        case .xhr: return "XHR"
        case .socket: return "Socket"
        case .resource: return "Resources"
        case .navigation: return "Navigation"
        case .other: return "Other"
        }
    }

    func matches(_ event: DeveloperLiveNetworkEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .fetch:
            return event.kind == "fetch"
        case .xhr:
            return event.kind == "xhr"
        case .socket:
            return event.kind == "websocket" || event.kind == "eventsource"
        case .resource:
            return event.kind == "resource"
        case .navigation:
            return event.kind == "navigation"
        case .other:
            return !["fetch", "xhr", "websocket", "eventsource", "resource", "navigation"].contains(event.kind)
        }
    }
}

private enum DeveloperLiveSessionFilter: Hashable {
    case all
    case session(String)

    func matches(_ event: DeveloperLiveNetworkEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .session(let title):
            return event.sessionTitle == title
        }
    }
}
