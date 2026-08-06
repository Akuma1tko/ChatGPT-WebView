import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var updateChecker: AppUpdateChecker
    @EnvironmentObject private var providerManager: AIProviderManager
    @EnvironmentObject private var profileManager: ChatGPTProfileManager
    @EnvironmentObject private var profileSessionPool: ChatGPTProfileSessionPool
    @Environment(\.openURL) private var openURL
    @AppStorage("developerModeEnabled") private var developerModeEnabled = false
    @State private var selectedTab: AppTab = .assistant
    @State private var isShowingProfiles = false
    @State private var isShowingSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                AIChatTabView()
                    .opacity(selectedTab == .assistant ? 1 : 0)
                    .allowsHitTesting(selectedTab == .assistant)
                    .accessibilityHidden(selectedTab != .assistant)
                    .zIndex(selectedTab == .assistant ? 1 : 0)

                MemoryTestView()
                    .opacity(selectedTab == .memory ? 1 : 0)
                    .allowsHitTesting(selectedTab == .memory)
                    .accessibilityHidden(selectedTab != .memory)
                    .zIndex(selectedTab == .memory ? 1 : 0)

                DeveloperToolsView(
                    isActive: developerModeEnabled && selectedTab == .developer
                )
                .opacity(developerModeEnabled && selectedTab == .developer ? 1 : 0)
                .allowsHitTesting(developerModeEnabled && selectedTab == .developer)
                .accessibilityHidden(!developerModeEnabled || selectedTab != .developer)
                .zIndex(developerModeEnabled && selectedTab == .developer ? 2 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 34)

            if isShowingProfiles {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isShowingProfiles = false
                    }
                    .zIndex(2)

                AIProfilePickerPopup(
                    providerManager: providerManager,
                    profileManager: profileManager,
                    onProviderSelected: { provider in
                        providerManager.selectProvider(provider)
                        selectedTab = .assistant
                        isShowingProfiles = false
                    },
                    onProfileSelected: { profile in
                        profileManager.selectProfile(profile, for: providerManager.activeProviderID)
                        selectedTab = .assistant
                        isShowingProfiles = false
                    },
                    onRemoveProfile: { profile in
                        removeProfile(profile, providerID: providerManager.activeProviderID)
                    },
                    onAddLogin: {
                        _ = profileManager.addLoginProfile(for: providerManager.activeProviderID)
                        selectedTab = .assistant
                        isShowingProfiles = false
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
                .zIndex(3)
            }

            CompactBottomSwitcher(
                selectedTab: $selectedTab,
                provider: providerManager.activeProvider,
                developerModeEnabled: developerModeEnabled,
                onProfiles: {
                    isShowingProfiles.toggle()
                },
                onSettings: {
                    isShowingProfiles = false
                    isShowingSettings = true
                }
            )
            .zIndex(4)
        }
        .onChange(of: appModel.openChatGPTTabRequestID) { _ in
            selectedTab = .assistant
            isShowingProfiles = false
        }
        .onChange(of: developerModeEnabled) { isEnabled in
            if !isEnabled && selectedTab == .developer {
                selectedTab = .assistant
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(updateChecker: updateChecker)
                .presentationDetents([.medium, .large])
        }
        .alert(item: $updateChecker.availableUpdate) { update in
            Alert(
                title: Text("Update Available"),
                message: Text("ContextPort \(update.version) is available. This IPA was built as version \(update.currentVersion)."),
                primaryButton: .default(Text("View Release")) {
                    openURL(update.releaseURL)
                },
                secondaryButton: .cancel(Text("Later"))
            )
        }
    }

    private func removeProfile(_ profile: ChatGPTProfile, providerID: AIProviderID) {
        guard profile.kind == .saved else { return }

        Task { @MainActor in
            await profileSessionPool.removeSavedProfileSession(
                providerID: providerID,
                profileID: profile.id
            )
            profileManager.removeSavedProfile(profile, for: providerID)
            selectedTab = .assistant
            isShowingProfiles = false
        }
    }
}

private enum AppTab: Hashable {
    case assistant
    case memory
    case developer
}

private struct CompactBottomSwitcher: View {
    @Binding var selectedTab: AppTab
    let provider: AIProvider
    let developerModeEnabled: Bool
    let onProfiles: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            CompactTabButton(
                title: provider.displayName,
                systemImage: provider.systemImage,
                isSelected: selectedTab == .assistant
            ) {
                selectedTab = .assistant
            }

            CompactTabButton(
                title: "Memory",
                systemImage: "externaldrive.connected.to.line.below.fill",
                isSelected: selectedTab == .memory
            ) {
                selectedTab = .memory
            }

            if developerModeEnabled {
                CompactTabButton(
                    title: "Dev",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    isSelected: selectedTab == .developer
                ) {
                    selectedTab = .developer
                }
            }

            Button(action: onProfiles) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 32)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI and profiles")

            Button(action: onSettings) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 32)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 0.5), alignment: .top)
    }
}

private struct AIProfilePickerPopup: View {
    @ObservedObject var providerManager: AIProviderManager
    @ObservedObject var profileManager: ChatGPTProfileManager
    let onProviderSelected: (AIProvider) -> Void
    let onProfileSelected: (ChatGPTProfile) -> Void
    let onRemoveProfile: (ChatGPTProfile) -> Void
    let onAddLogin: () -> Void

    private var providerID: AIProviderID {
        providerManager.activeProviderID
    }

    var body: some View {
        VStack(spacing: 0) {
            providerStrip

            Divider()

            profileRow(
                profileManager.primaryProfile(for: providerID),
                title: primaryProfileTitle,
                removable: false
            )
            profileRow(
                profileManager.guestProfile(for: providerID),
                title: "Guest",
                removable: false
            )

            ForEach(profileManager.savedProfiles(for: providerID)) { profile in
                profileRow(profile, title: profile.displayName, removable: true)
            }

            Divider()

            Button(action: onAddLogin) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .frame(width: 18)
                    Text("Add \(providerManager.activeProvider.displayName) Login")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(radius: 8)
    }

    private var providerStrip: some View {
        HStack(spacing: 0) {
            ForEach(providerManager.providers) { provider in
                Button {
                    onProviderSelected(provider)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: provider.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                        Text(provider.displayName)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundColor(
                        providerManager.activeProviderID == provider.id
                            ? .accentColor
                            : .secondary
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(provider.displayName)
            }
        }
    }

    private var primaryProfileTitle: String {
        let displayName = profileManager.primaryDisplayName(for: providerID)
        return displayName == "Current User"
            ? "Current User"
            : "Current User: \(displayName)"
    }

    @ViewBuilder
    private func profileRow(_ profile: ChatGPTProfile, title: String, removable: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                onProfileSelected(profile)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: profileManager.activeProfileID(for: providerID) == profile.id ? "checkmark" : "")
                        .frame(width: 18)
                    Text(title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.leading, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if removable {
                Button {
                    onRemoveProfile(profile)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(title)")
            }
        }
    }
}

private struct CompactTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct SettingsView: View {
    @ObservedObject var updateChecker: AppUpdateChecker
    @EnvironmentObject private var providerManager: AIProviderManager
    @EnvironmentObject private var profileSessionPool: ChatGPTProfileSessionPool
    @EnvironmentObject private var launchSettings: MemoryLaunchSettings
    @EnvironmentObject private var chatPerformanceSettings: ChatPerformanceSettings
    @AppStorage(ChatGPTProfileSessionPool.restoreLastChatDefaultsKey) private var restoreLastChatEnabled = true
    @AppStorage("StartChatGPTChatsAsTemporary") private var startChatGPTChatsAsTemporary = true
    @AppStorage("developerModeEnabled") private var developerModeEnabled = false
    @Environment(\.dismiss) private var dismiss
    @State private var showingRestartNotice = false

    private let developerSupportURL = URL(string: "https://buymeacoffee.com/spotterdeer")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(providerManager.allProviders) { provider in
                        Toggle(isOn: providerBinding(provider.id)) {
                            Label(provider.displayName, systemImage: provider.systemImage)
                        }
                    }
                } header: {
                    Text("AI Providers")
                } footer: {
                    Text("Choose which AIs are available throughout ContextPort. At least one AI must remain enabled.")
                }

                Section {
                    Toggle(isOn: $startChatGPTChatsAsTemporary) {
                        Label("Start New Chats as Temporary", systemImage: "eye.slash.fill")
                    }
                } header: {
                    Text("ChatGPT Privacy")
                } footer: {
                    Text("When enabled, each fresh ChatGPT composer starts in Temporary Chat. Existing conversations and other AI providers are unchanged. Turning this off affects future new chats.")
                }

                Section {
                    Toggle("Enable Access First", isOn: $chatPerformanceSettings.progressiveChatAccessEnabled)

                    Stepper(
                        value: $chatPerformanceSettings.progressiveAccessBucketCount,
                        in: ChatPerformanceSettings.progressiveAccessBucketRange
                    ) {
                        HStack {
                            Text("Access Buckets")
                            Spacer()
                            Text("\(chatPerformanceSettings.progressiveAccessBucketCount)")
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!chatPerformanceSettings.progressiveChatAccessEnabled)

                    HStack {
                        Text("Final Recovery Attempt")
                        Spacer()
                        Text(accessBucketFinalDelayText)
                            .foregroundColor(.secondary)
                    }

                    Button("Save Settings for Restart") {
                        showingRestartNotice = true
                    }
                } header: {
                    Text("Progressive Chat Access")
                } footer: {
                    Text("Access First lets already rendered chat content become scrollable while ChatGPT continues loading. Changes save automatically. For a clean comparison, fully close ContextPort from the app switcher and reopen the same Work chat.")
                }

                ExperimentalChatOptimizationSettingsView()

                Section {
                    Toggle("Optimize Long Chats", isOn: $chatPerformanceSettings.isEnabled)
                        .disabled(chatPerformanceSettings.latestExchangeOnly)

                    Toggle(isOn: $chatPerformanceSettings.latestExchangeOnly) {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .frame(width: 22)
                            Text("Latest Exchange Only")
                        }
                    }

                    Stepper(
                        value: renderBucketBinding,
                        in: 1...(ChatPerformanceSettings.visibleMessageRange.upperBound / ChatPerformanceSettings.messagesPerRenderBucket)
                    ) {
                        HStack {
                            Text("Render Buckets")
                            Spacer()
                            Text("\(chatPerformanceSettings.renderBucketCount) • \(chatPerformanceSettings.visibleMessageLimit) messages")
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!chatPerformanceSettings.isEnabled || chatPerformanceSettings.latestExchangeOnly)

                    Text("Optimize On")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(providerManager.allProviders) { provider in
                        Toggle(isOn: performanceProviderBinding(provider.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: provider.systemImage)
                                    .frame(width: 22)
                                Text(provider.displayName)
                                if provider.id == .grok {
                                    Text("Experimental")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else if provider.id == .deepSeek {
                                    Text("Capture Required")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(provider.id == .deepSeek)
                    }

                    Divider()

                    Toggle(isOn: $chatPerformanceSettings.chatGPTMobileWebFallbackEnabled) {
                        HStack(spacing: 8) {
                            Image(systemName: AIProviderID.chatGPT.provider.systemImage)
                                .frame(width: 22)
                            Text("ChatGPT Mobile Fallback")
                            Text("Experimental")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Chat Performance")
                } footer: {
                    Text("Each render bucket represents five visible messages. Older loaded messages remain available to Save Context. Latest Exchange Only overrides the normal render window. ChatGPT Mobile Fallback adds mweb_fallback=1 only when the parameter is missing.")
                }

                Section("Memory Sharing") {
                    Picker("Context Format", selection: $launchSettings.sharingFormat) {
                        ForEach(MemorySharingFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $restoreLastChatEnabled) {
                        Label("Restore Last Chat", systemImage: "clock.arrow.circlepath")
                    }
                    .onChange(of: restoreLastChatEnabled) { isEnabled in
                        profileSessionPool.updateRestoreLastChatEnabled(isEnabled)
                    }
                } header: {
                    Text("Startup")
                } footer: {
                    Text("When off, ContextPort keeps your account sign-ins but opens each AI at its home page the next time the app starts. The currently open chat remains open until you leave it or close the app.")
                }

                Section {
                    Toggle(isOn: $developerModeEnabled) {
                        Label("Developer Mode", systemImage: "hammer.fill")
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Adds a Dev tab with separate Static source capture and Live WKWebView interception. Static indexing remains manual. Live capture runs only after Start Live Capture is pressed and continues while you return to an AI tab until explicitly stopped.")
                }

                Section("Updates") {
                    Toggle("Check for updates on start", isOn: $updateChecker.checkForUpdatesOnStart)
                }

                Section {
                    Link(destination: developerSupportURL) {
                        Label("Buy the Developer a Coffee", systemImage: "cup.and.saucer.fill")
                    }
                } header: {
                    Text("Support Development")
                } footer: {
                    Text("Opens Buy Me a Coffee in your default browser.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Settings Saved", isPresented: $showingRestartNotice) {
                Button("Close Settings") {
                    dismiss()
                }
                Button("Keep Adjusting", role: .cancel) {}
            } message: {
                Text("Fully close ContextPort from the app switcher, then reopen it to test the selected access, follow, rendering, and media controls from a clean start.")
            }
        }
    }

    private var renderBucketBinding: Binding<Int> {
        Binding(
            get: {
                chatPerformanceSettings.renderBucketCount
            },
            set: { bucketCount in
                chatPerformanceSettings.setRenderBucketCount(bucketCount)
            }
        )
    }

    private var accessBucketFinalDelayText: String {
        let labels = [
            "0.25 seconds", "0.75 seconds", "2 seconds", "5 seconds",
            "10 seconds", "16 seconds", "24 seconds", "32 seconds",
            "45 seconds", "60 seconds", "90 seconds", "120 seconds"
        ]
        let index = min(
            max(chatPerformanceSettings.progressiveAccessBucketCount - 1, 0),
            labels.count - 1
        )
        return labels[index]
    }

    private func providerBinding(_ providerID: AIProviderID) -> Binding<Bool> {
        Binding(
            get: {
                providerManager.isProviderEnabled(providerID)
            },
            set: { isEnabled in
                providerManager.setProviderEnabled(providerID, enabled: isEnabled)
            }
        )
    }

    private func performanceProviderBinding(_ providerID: AIProviderID) -> Binding<Bool> {
        Binding(
            get: {
                chatPerformanceSettings.isProviderEnabled(providerID)
            },
            set: { isEnabled in
                chatPerformanceSettings.setProviderEnabled(providerID, enabled: isEnabled)
            }
        )
    }
}

struct SupabaseSetupRequiredView: View {
    var body: some View {
        NavigationView {
            Text("Memory is local and available on this device.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .navigationTitle("Memory")
        }
    }
}
