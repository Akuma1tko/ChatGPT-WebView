import SwiftUI

struct DeveloperToolsView: View {
    let isActive: Bool

    @State private var selectedTool: DeveloperTool = .staticSources

    var body: some View {
        VStack(spacing: 0) {
            Picker("Developer Tool", selection: $selectedTool) {
                ForEach(DeveloperTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.systemImage)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ZStack {
                DeveloperSourcesView(
                    isActive: isActive && selectedTool == .staticSources
                )
                .opacity(selectedTool == .staticSources ? 1 : 0)
                .allowsHitTesting(selectedTool == .staticSources)
                .accessibilityHidden(selectedTool != .staticSources)

                DeveloperLiveInterceptorView(
                    isActive: isActive && selectedTool == .liveInterceptor
                )
                .opacity(selectedTool == .liveInterceptor ? 1 : 0)
                .allowsHitTesting(selectedTool == .liveInterceptor)
                .accessibilityHidden(selectedTool != .liveInterceptor)
            }
        }
    }
}

private enum DeveloperTool: String, CaseIterable, Identifiable {
    case staticSources
    case liveInterceptor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .staticSources:
            return "Static"
        case .liveInterceptor:
            return "Live"
        }
    }

    var systemImage: String {
        switch self {
        case .staticSources:
            return "doc.text.magnifyingglass"
        case .liveInterceptor:
            return "waveform.path.ecg"
        }
    }
}
