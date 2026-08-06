import Combine
import Foundation
import WebKit

struct DeveloperLiveNetworkEvent: Identifiable, Codable, Sendable {
    let id: String
    let sessionID: String
    let sessionTitle: String
    let pageURL: String
    let timestamp: Date
    let kind: String
    let phase: String
    let method: String?
    let url: String?
    let status: Int?
    let durationMilliseconds: Double?
    let mimeType: String?
    let transferSize: Int?
    let requestBodyPreview: String?
    let responseBodyPreview: String?
    let detail: String?

    var displayURL: String {
        let candidate = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? pageURL : candidate
    }

    var primaryLabel: String {
        let type = kind.uppercased()
        if let method, !method.isEmpty { return "\(method) · \(type) · \(phase)" }
        return "\(type) · \(phase)"
    }

    var searchText: String {
        [sessionTitle, pageURL, kind, phase, method, url, status.map { String($0) },
         mimeType, requestBodyPreview, responseBodyPreview, detail]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

@MainActor
final class DeveloperLiveInterceptorModel: ObservableObject {
    @Published private(set) var events: [DeveloperLiveNetworkEvent] = []
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Live capture is stopped."
    @Published private(set) var droppedEventCount = 0
    @Published private(set) var snapshotGeneration = 0

    private struct BrowserDrainEnvelope: Decodable {
        let events: [BrowserEvent]
        let dropped: Int?
    }

    private struct BrowserEvent: Decodable {
        let id: String?
        let timestamp: Double?
        let kind: String?
        let phase: String?
        let method: String?
        let url: String?
        let status: Int?
        let duration: Double?
        let mimeType: String?
        let transferSize: Int?
        let requestBody: String?
        let responseBody: String?
        let detail: String?
    }

    private static let maximumEvents = 2_000
    private static let pollIntervalNanoseconds: UInt64 = 750_000_000

    private var sessions: [DeveloperWebViewSession] = []
    private var pollTask: Task<Void, Never>?
    private var captureBodyPreviews = false

    var sessionTitles: [String] {
        Array(Set(events.map(\.sessionTitle))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func start(sessions: [DeveloperWebViewSession], captureBodyPreviews: Bool) {
        guard !isCapturing else { return }
        guard !sessions.isEmpty else {
            status = "No loaded provider WKWebView is available. Open an AI tab first."
            return
        }

        self.sessions = sessions
        self.captureBodyPreviews = captureBodyPreviews
        isCapturing = true
        status = "Listening across \(sessions.count) loaded provider session\(sessions.count == 1 ? "" : "s")..."

        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isCapturing {
                await self.pollAllSessions()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        status = "Live capture stopped with \(events.count) retained event\(events.count == 1 ? "" : "s")."
        pollTask?.cancel()
        pollTask = nil

        let sessions = self.sessions
        Task { @MainActor in
            for session in sessions {
                try? await session.webView.evaluateJavaScript(DeveloperLiveInterceptorScript.disable)
            }
        }
    }

    func clear() {
        guard !events.isEmpty || droppedEventCount > 0 else { return }
        events.removeAll(keepingCapacity: true)
        droppedEventCount = 0
        snapshotGeneration &+= 1
        status = isCapturing ? "Live log cleared. Still listening..." : "Live log cleared."
    }

    func updateBodyPreviewCapture(_ enabled: Bool) {
        captureBodyPreviews = enabled
    }

    deinit { pollTask?.cancel() }

    private func pollAllSessions() async {
        var capturedThisCycle = 0

        for session in sessions {
            guard !Task.isCancelled, isCapturing else { return }
            do {
                let raw = try await session.webView.evaluateJavaScript(
                    DeveloperLiveInterceptorScript.installAndDrain(
                        captureBodyPreviews: captureBodyPreviews
                    )
                )
                guard let json = raw as? String,
                      let data = json.data(using: .utf8) else { continue }

                let envelope = try JSONDecoder().decode(BrowserDrainEnvelope.self, from: data)
                let browserDropped = envelope.dropped ?? 0
                if browserDropped > 0 {
                    droppedEventCount += browserDropped
                    snapshotGeneration &+= 1
                }

                let pageURL = session.webView.url?.absoluteString ?? ""
                let mapped = envelope.events.map { item in
                    DeveloperLiveNetworkEvent(
                        id: "\(session.id)::\(item.id ?? UUID().uuidString)",
                        sessionID: session.id,
                        sessionTitle: session.title,
                        pageURL: pageURL,
                        timestamp: Date(timeIntervalSince1970:
                            (item.timestamp ?? Date().timeIntervalSince1970 * 1_000) / 1_000),
                        kind: item.kind ?? "other",
                        phase: item.phase ?? "event",
                        method: item.method,
                        url: item.url,
                        status: item.status,
                        durationMilliseconds: item.duration,
                        mimeType: item.mimeType,
                        transferSize: item.transferSize,
                        requestBodyPreview: item.requestBody,
                        responseBodyPreview: item.responseBody,
                        detail: item.detail
                    )
                }
                append(mapped)
                capturedThisCycle += mapped.count
            } catch {
                // A navigation may replace the JavaScript world between install and drain.
                // The next bounded poll reinstalls the bridge on the new document.
            }
        }

        if capturedThisCycle > 0 {
            status = "Listening · \(events.count) retained event\(events.count == 1 ? "" : "s")"
        }
    }

    private func append(_ incoming: [DeveloperLiveNetworkEvent]) {
        guard !incoming.isEmpty else { return }
        events.append(contentsOf: incoming)
        let overflow = events.count - Self.maximumEvents
        if overflow > 0 {
            events.removeFirst(overflow)
            droppedEventCount += overflow
        }
        snapshotGeneration &+= 1
    }
}
