import SwiftUI

enum ChatOptimizationPreset: String, CaseIterable, Identifiable {
    case compatibility
    case balanced
    case aggressive
    case extreme
    case diagnostic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compatibility: return "Compatibility"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        case .extreme: return "Extreme"
        case .diagnostic: return "Diagnostic"
        }
    }
}

struct ExperimentalChatOptimizationSettingsView: View {
    @EnvironmentObject private var chatPerformanceSettings: ChatPerformanceSettings

    @AppStorage(AIProfileManager.hideLoggedInUserNameDefaultsKey) private var hideLoggedInUserName = false
    @AppStorage("ChatGPTOptimizationPreset") private var selectedPresetRaw = ChatOptimizationPreset.balanced.rawValue

    @AppStorage("ChatGPTRecoveryDelayScalePercent") private var recoveryDelayScalePercent = 100
    @AppStorage("ChatGPTRecoveryPassCount") private var recoveryPassCount = 1
    @AppStorage("ChatGPTRecoveryPassGapSeconds") private var recoveryPassGapSeconds = 20
    @AppStorage("ChatGPTRunRecoveryOnAttachEnabled") private var runRecoveryOnAttachEnabled = true
    @AppStorage("ChatGPTRunRecoveryOnForegroundEnabled") private var runRecoveryOnForegroundEnabled = true
    @AppStorage("ChatGPTRunRecoveryOnMemoryWarningEnabled") private var runRecoveryOnMemoryWarningEnabled = false
    @AppStorage("ChatGPTPrepareNativeScrollEachAttemptEnabled") private var prepareNativeScrollEachAttemptEnabled = true

    @AppStorage("ChatGPTForceNativeScrollEnabled") private var forceNativeScrollEnabled = true
    @AppStorage("ChatGPTDirectionalLockEnabled") private var directionalLockEnabled = true
    @AppStorage("ChatGPTDisableOuterBounceEnabled") private var disableOuterBounceEnabled = true
    @AppStorage("ChatGPTDelayContentTouchesEnabled") private var delayContentTouchesEnabled = false
    @AppStorage("ChatGPTShowVerticalScrollIndicatorEnabled") private var showVerticalScrollIndicatorEnabled = true
    @AppStorage("ChatGPTShowHorizontalScrollIndicatorEnabled") private var showHorizontalScrollIndicatorEnabled = false

    @AppStorage("ChatGPTFollowLatestEnabled") private var followLatestEnabled = true
    @AppStorage("ChatGPTStartFollowingLatestEnabled") private var startFollowingLatestEnabled = true
    @AppStorage("ChatGPTFollowIntervalMilliseconds") private var followIntervalMilliseconds = 500
    @AppStorage("ChatGPTNearBottomThresholdPoints") private var nearBottomThresholdPoints = 80
    @AppStorage("ChatGPTUpwardScrollThresholdPoints") private var upwardScrollThresholdPoints = 4
    @AppStorage("ChatGPTProgrammaticScrollGuardMilliseconds") private var programmaticScrollGuardMilliseconds = 250
    @AppStorage("ChatGPTMaximumFollowDurationSeconds") private var maximumFollowDurationSeconds = 0

    @AppStorage("ChatGPTRescanMissingTargetEnabled") private var rescanMissingTargetEnabled = true
    @AppStorage("ChatGPTIncludeDocumentRootsEnabled") private var includeDocumentRootsEnabled = true
    @AppStorage("ChatGPTPreferConversationContainerEnabled") private var preferConversationContainerEnabled = true
    @AppStorage("ChatGPTTargetMinimumHeightPoints") private var targetMinimumHeightPoints = 160
    @AppStorage("ChatGPTTargetMinimumScrollRangePoints") private var targetMinimumScrollRangePoints = 40

    @AppStorage("ChatGPTUseContentVisibilityEnabled") private var useContentVisibilityEnabled = false
    @AppStorage("ChatGPTUseCSSContainmentEnabled") private var useCSSContainmentEnabled = false
    @AppStorage("ChatGPTDeferOffscreenImagesEnabled") private var deferOffscreenImagesEnabled = false
    @AppStorage("ChatGPTPauseOffscreenMediaEnabled") private var pauseOffscreenMediaEnabled = false
    @AppStorage("ChatGPTHideEmbeddedFramesEnabled") private var hideEmbeddedFramesEnabled = false
    @AppStorage("ChatGPTHideCanvasEnabled") private var hideCanvasEnabled = false
    @AppStorage("ChatGPTDisableAnimationsEnabled") private var disableAnimationsEnabled = false
    @AppStorage("ChatGPTReduceVisualEffectsEnabled") private var reduceVisualEffectsEnabled = false
    @AppStorage("ChatGPTHideSidebarEnabled") private var hideSidebarEnabled = false
    @AppStorage("ChatGPTHideHeaderEnabled") private var hideHeaderEnabled = false
    @AppStorage("ChatGPTOptimizeCodeBlocksEnabled") private var optimizeCodeBlocksEnabled = false
    @AppStorage("ChatGPTMaximumImageHeightPoints") private var maximumImageHeightPoints = 0
    @AppStorage("ChatGPTDOMOptimizationIntervalMilliseconds") private var domOptimizationIntervalMilliseconds = 2500

    @AppStorage("ChatGPTOptimizationDiagnosticsEnabled") private var diagnosticsEnabled = false
    @AppStorage("ChatGPTLogTargetSelectionEnabled") private var logTargetSelectionEnabled = false
    @AppStorage("ChatGPTLogDOMCountsEnabled") private var logDOMCountsEnabled = false

    @State private var showingResetConfirmation = false

    private var selectedPreset: ChatOptimizationPreset {
        ChatOptimizationPreset(rawValue: selectedPresetRaw) ?? .balanced
    }

    var body: some View {
        Group {
            screenRecordingPrivacySection

            Section {
                Picker("Preset", selection: $selectedPresetRaw) {
                    ForEach(ChatOptimizationPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset.rawValue)
                    }
                }

                Button("Apply Selected Preset") {
                    applyPreset(selectedPreset)
                }

                Button("Reset All Optimization Settings", role: .destructive) {
                    showingResetConfirmation = true
                }
            } header: {
                Text("Optimization Test Presets")
            } footer: {
                Text("Balanced is an active test preset. Reset restores ContextPort's factory optimization defaults: Access First on with six buckets, long-chat filtering off, one render bucket, diagnostics off, provider defaults restored, and ChatGPT Mobile Fallback off.")
            }

            recoverySchedulingSection
            nativeWebViewSection
            followLatestSection
            targetDetectionSection
            renderingPressureSection
            diagnosticsSection
        }
        .onChange(of: settingsSignature) { _ in
            NotificationCenter.default.post(
                name: ChatPerformanceSettings.progressiveAccessSettingsDidChangeNotification,
                object: nil
            )
        }
        .alert("Reset Optimization Settings?", isPresented: $showingResetConfirmation) {
            Button("Reset to Defaults", role: .destructive) {
                resetToFactoryDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets every access, render, recovery, scrolling, media, diagnostic, provider optimization, and mobile fallback setting. AI sign-ins, saved chats, Memory, and other app settings are not changed.")
        }
    }

    private var screenRecordingPrivacySection: some View {
        Section {
            Toggle(isOn: $hideLoggedInUserName) {
                Label("Hide Logged In User Name", systemImage: "eye.slash.fill")
            }
        } header: {
            Text("Screen Recording Privacy")
        } footer: {
            Text("When enabled, the AI selector shows Current User instead of the detected logged-in account name. The stored name, login session, and saved profiles are not changed, and turning this off restores the normal label.")
        }
    }

    private var recoverySchedulingSection: some View {
        Section {
            Stepper(value: $recoveryDelayScalePercent, in: 25...400, step: 25) {
                settingRow("Recovery Delay Scale", value: "\(recoveryDelayScalePercent)%")
            }
            Stepper(value: $recoveryPassCount, in: 1...3) {
                settingRow("Recovery Passes", value: "\(recoveryPassCount)")
            }
            Stepper(value: $recoveryPassGapSeconds, in: 5...120, step: 5) {
                settingRow("Pass Gap", value: "\(recoveryPassGapSeconds) sec")
            }
            Toggle("Run Recovery When WebView Attaches", isOn: $runRecoveryOnAttachEnabled)
            Toggle("Run Recovery When App Returns", isOn: $runRecoveryOnForegroundEnabled)
            Toggle("Run Recovery After Memory Warning", isOn: $runRecoveryOnMemoryWarningEnabled)
            Toggle("Prepare Native Scroll Every Attempt", isOn: $prepareNativeScrollEachAttemptEnabled)
        } header: {
            Text("Recovery Scheduling")
        } footer: {
            Text("Delay scale changes every access bucket. Multiple passes repeat the selected bucket schedule after the chosen gap. All work remains bounded and generation scoped.")
        }
    }

    private var nativeWebViewSection: some View {
        Section {
            Toggle("Force Native Scrolling", isOn: $forceNativeScrollEnabled)
            Toggle("Directional Lock", isOn: $directionalLockEnabled)
            Toggle("Disable Outer WebView Bounce", isOn: $disableOuterBounceEnabled)
            Toggle("Delay Content Touches", isOn: $delayContentTouchesEnabled)
            Toggle("Show Vertical Scroll Indicator", isOn: $showVerticalScrollIndicatorEnabled)
            Toggle("Show Horizontal Scroll Indicator", isOn: $showHorizontalScrollIndicatorEnabled)
        } header: {
            Text("Native WebView")
        } footer: {
            Text("These controls change the outer WKWebView scroll view. ChatGPT usually scrolls inside a separate DOM container, so combinations may behave differently while the page hydrates.")
        }
    }

    private var followLatestSection: some View {
        Section {
            Toggle("Enable Follow Latest", isOn: $followLatestEnabled)
            Toggle("Start New Chats Following Latest", isOn: $startFollowingLatestEnabled)
            Stepper(value: $followIntervalMilliseconds, in: 250...3000, step: 250) {
                settingRow("Follow Check", value: "\(followIntervalMilliseconds) ms")
            }
            Stepper(value: $nearBottomThresholdPoints, in: 20...300, step: 20) {
                settingRow("Near Bottom Threshold", value: "\(nearBottomThresholdPoints) pt")
            }
            Stepper(value: $upwardScrollThresholdPoints, in: 1...24) {
                settingRow("Upward Handoff", value: "\(upwardScrollThresholdPoints) pt")
            }
            Stepper(value: $programmaticScrollGuardMilliseconds, in: 100...1500, step: 50) {
                settingRow("Scroll Guard", value: "\(programmaticScrollGuardMilliseconds) ms")
            }
            Stepper(value: $maximumFollowDurationSeconds, in: 0...600, step: 30) {
                settingRow(
                    "Maximum Follow Time",
                    value: maximumFollowDurationSeconds == 0 ? "Unlimited" : "\(maximumFollowDurationSeconds) sec"
                )
            }
        } header: {
            Text("Follow Latest")
        } footer: {
            Text("A shorter follow check reacts faster but performs more JavaScript work. Maximum Follow Time zero means follow until the user deliberately scrolls upward.")
        }
    }

    private var targetDetectionSection: some View {
        Section {
            Toggle("Rescan When Target Disappears", isOn: $rescanMissingTargetEnabled)
            Toggle("Include Document Roots", isOn: $includeDocumentRootsEnabled)
            Toggle("Prefer Conversation Containers", isOn: $preferConversationContainerEnabled)
            Stepper(value: $targetMinimumHeightPoints, in: 80...600, step: 20) {
                settingRow("Minimum Target Height", value: "\(targetMinimumHeightPoints) pt")
            }
            Stepper(value: $targetMinimumScrollRangePoints, in: 20...400, step: 20) {
                settingRow("Minimum Scroll Range", value: "\(targetMinimumScrollRangePoints) pt")
            }
        } header: {
            Text("Scroll Target Detection")
        } footer: {
            Text("Disabling rescans minimizes DOM queries but can leave scrolling unfixed if ChatGPT replaces its scroll container during hydration.")
        }
    }

    private var renderingPressureSection: some View {
        Section {
            Toggle("Use Content Visibility", isOn: $useContentVisibilityEnabled)
            Toggle("Use CSS Containment", isOn: $useCSSContainmentEnabled)
            Toggle("Defer Offscreen Images", isOn: $deferOffscreenImagesEnabled)
            Toggle("Pause Offscreen Audio and Video", isOn: $pauseOffscreenMediaEnabled)
            Toggle("Hide Embedded Frames", isOn: $hideEmbeddedFramesEnabled)
            Toggle("Hide Canvas Content", isOn: $hideCanvasEnabled)
            Toggle("Disable Animations and Transitions", isOn: $disableAnimationsEnabled)
            Toggle("Reduce Blur, Filters, and Shadows", isOn: $reduceVisualEffectsEnabled)
            Toggle("Hide ChatGPT Sidebar", isOn: $hideSidebarEnabled)
            Toggle("Hide ChatGPT Header", isOn: $hideHeaderEnabled)
            Toggle("Optimize Code Blocks", isOn: $optimizeCodeBlocksEnabled)
            Stepper(value: $maximumImageHeightPoints, in: 0...1600, step: 100) {
                settingRow(
                    "Maximum Image Height",
                    value: maximumImageHeightPoints == 0 ? "Original" : "\(maximumImageHeightPoints) pt"
                )
            }
            Stepper(value: $domOptimizationIntervalMilliseconds, in: 1000...10000, step: 500) {
                settingRow("DOM Optimization Check", value: "\(domOptimizationIntervalMilliseconds) ms")
            }
        } header: {
            Text("Rendering and Media Pressure")
        } footer: {
            Text("These are increasingly invasive experiments. Hidden frames, canvases, sidebars, or headers may remove provider controls or interactive results. Verify Save Context after every combination.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Toggle("Optimization Diagnostics", isOn: $diagnosticsEnabled)
            Toggle("Log Scroll Target Selection", isOn: $logTargetSelectionEnabled)
                .disabled(!diagnosticsEnabled)
            Toggle("Log DOM and Media Counts", isOn: $logDOMCountsEnabled)
                .disabled(!diagnosticsEnabled)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Diagnostics add console logging and should be disabled during normal performance comparisons unless log evidence is needed.")
        }
    }

    @ViewBuilder
    private func settingRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private var settingsSignature: String {
        [
            selectedPresetRaw,
            String(recoveryDelayScalePercent), String(recoveryPassCount), String(recoveryPassGapSeconds),
            String(runRecoveryOnAttachEnabled), String(runRecoveryOnForegroundEnabled),
            String(runRecoveryOnMemoryWarningEnabled), String(prepareNativeScrollEachAttemptEnabled),
            String(forceNativeScrollEnabled), String(directionalLockEnabled), String(disableOuterBounceEnabled),
            String(delayContentTouchesEnabled), String(showVerticalScrollIndicatorEnabled),
            String(showHorizontalScrollIndicatorEnabled), String(followLatestEnabled),
            String(startFollowingLatestEnabled), String(followIntervalMilliseconds),
            String(nearBottomThresholdPoints), String(upwardScrollThresholdPoints),
            String(programmaticScrollGuardMilliseconds), String(maximumFollowDurationSeconds),
            String(rescanMissingTargetEnabled), String(includeDocumentRootsEnabled),
            String(preferConversationContainerEnabled), String(targetMinimumHeightPoints),
            String(targetMinimumScrollRangePoints), String(useContentVisibilityEnabled),
            String(useCSSContainmentEnabled), String(deferOffscreenImagesEnabled),
            String(pauseOffscreenMediaEnabled), String(hideEmbeddedFramesEnabled),
            String(hideCanvasEnabled), String(disableAnimationsEnabled), String(reduceVisualEffectsEnabled),
            String(hideSidebarEnabled), String(hideHeaderEnabled), String(optimizeCodeBlocksEnabled),
            String(maximumImageHeightPoints), String(domOptimizationIntervalMilliseconds),
            String(diagnosticsEnabled), String(logTargetSelectionEnabled), String(logDOMCountsEnabled)
        ].joined(separator: "|")
    }

    private func applyPreset(_ preset: ChatOptimizationPreset) {
        selectedPresetRaw = preset.rawValue

        switch preset {
        case .compatibility:
            chatPerformanceSettings.progressiveChatAccessEnabled = false
            chatPerformanceSettings.isEnabled = false
            chatPerformanceSettings.latestExchangeOnly = false
            recoveryDelayScalePercent = 100
            recoveryPassCount = 1
            recoveryPassGapSeconds = 20
            runRecoveryOnAttachEnabled = false
            runRecoveryOnForegroundEnabled = false
            runRecoveryOnMemoryWarningEnabled = false
            prepareNativeScrollEachAttemptEnabled = false
            forceNativeScrollEnabled = false
            directionalLockEnabled = false
            disableOuterBounceEnabled = false
            delayContentTouchesEnabled = true
            showVerticalScrollIndicatorEnabled = true
            showHorizontalScrollIndicatorEnabled = true
            followLatestEnabled = false
            startFollowingLatestEnabled = false
            rescanMissingTargetEnabled = false
            includeDocumentRootsEnabled = true
            preferConversationContainerEnabled = false
            clearRenderingPressureOptions()

        case .balanced:
            chatPerformanceSettings.progressiveChatAccessEnabled = true
            chatPerformanceSettings.progressiveAccessBucketCount = 6
            chatPerformanceSettings.latestExchangeOnly = false
            chatPerformanceSettings.isEnabled = true
            chatPerformanceSettings.setRenderBucketCount(5)
            recoveryDelayScalePercent = 100
            recoveryPassCount = 1
            recoveryPassGapSeconds = 20
            runRecoveryOnAttachEnabled = true
            runRecoveryOnForegroundEnabled = true
            runRecoveryOnMemoryWarningEnabled = false
            prepareNativeScrollEachAttemptEnabled = true
            configureNativeDefaults()
            configureFollowDefaults()
            configureTargetDefaults()
            clearRenderingPressureOptions()

        case .aggressive:
            chatPerformanceSettings.progressiveChatAccessEnabled = true
            chatPerformanceSettings.progressiveAccessBucketCount = 9
            chatPerformanceSettings.latestExchangeOnly = false
            chatPerformanceSettings.isEnabled = true
            chatPerformanceSettings.setRenderBucketCount(3)
            recoveryDelayScalePercent = 75
            recoveryPassCount = 2
            recoveryPassGapSeconds = 20
            runRecoveryOnAttachEnabled = true
            runRecoveryOnForegroundEnabled = true
            runRecoveryOnMemoryWarningEnabled = true
            prepareNativeScrollEachAttemptEnabled = true
            configureNativeDefaults()
            configureFollowDefaults()
            configureTargetDefaults()
            useContentVisibilityEnabled = true
            useCSSContainmentEnabled = false
            deferOffscreenImagesEnabled = true
            pauseOffscreenMediaEnabled = true
            hideEmbeddedFramesEnabled = false
            hideCanvasEnabled = false
            disableAnimationsEnabled = true
            reduceVisualEffectsEnabled = true
            hideSidebarEnabled = false
            hideHeaderEnabled = false
            optimizeCodeBlocksEnabled = true
            maximumImageHeightPoints = 900
            domOptimizationIntervalMilliseconds = 2500

        case .extreme:
            chatPerformanceSettings.progressiveChatAccessEnabled = true
            chatPerformanceSettings.progressiveAccessBucketCount = 12
            chatPerformanceSettings.latestExchangeOnly = true
            chatPerformanceSettings.isEnabled = false
            chatPerformanceSettings.setRenderBucketCount(1)
            recoveryDelayScalePercent = 50
            recoveryPassCount = 3
            recoveryPassGapSeconds = 15
            runRecoveryOnAttachEnabled = true
            runRecoveryOnForegroundEnabled = true
            runRecoveryOnMemoryWarningEnabled = true
            prepareNativeScrollEachAttemptEnabled = true
            configureNativeDefaults()
            configureFollowDefaults()
            followIntervalMilliseconds = 750
            configureTargetDefaults()
            useContentVisibilityEnabled = true
            useCSSContainmentEnabled = true
            deferOffscreenImagesEnabled = true
            pauseOffscreenMediaEnabled = true
            hideEmbeddedFramesEnabled = true
            hideCanvasEnabled = true
            disableAnimationsEnabled = true
            reduceVisualEffectsEnabled = true
            hideSidebarEnabled = true
            hideHeaderEnabled = true
            optimizeCodeBlocksEnabled = true
            maximumImageHeightPoints = 600
            domOptimizationIntervalMilliseconds = 1500

        case .diagnostic:
            chatPerformanceSettings.progressiveChatAccessEnabled = true
            chatPerformanceSettings.progressiveAccessBucketCount = 12
            chatPerformanceSettings.latestExchangeOnly = false
            chatPerformanceSettings.isEnabled = false
            recoveryDelayScalePercent = 100
            recoveryPassCount = 1
            recoveryPassGapSeconds = 20
            runRecoveryOnAttachEnabled = true
            runRecoveryOnForegroundEnabled = true
            runRecoveryOnMemoryWarningEnabled = true
            prepareNativeScrollEachAttemptEnabled = true
            configureNativeDefaults()
            configureFollowDefaults()
            configureTargetDefaults()
            clearRenderingPressureOptions()
            diagnosticsEnabled = true
            logTargetSelectionEnabled = true
            logDOMCountsEnabled = true
        }
    }

    private func resetToFactoryDefaults() {
        selectedPresetRaw = ChatOptimizationPreset.balanced.rawValue
        chatPerformanceSettings.resetToFactoryOptimizationDefaults()

        recoveryDelayScalePercent = 100
        recoveryPassCount = 1
        recoveryPassGapSeconds = 20
        runRecoveryOnAttachEnabled = true
        runRecoveryOnForegroundEnabled = true
        runRecoveryOnMemoryWarningEnabled = false
        prepareNativeScrollEachAttemptEnabled = true
        configureNativeDefaults()
        configureFollowDefaults()
        configureTargetDefaults()
        clearRenderingPressureOptions()
    }

    private func configureNativeDefaults() {
        forceNativeScrollEnabled = true
        directionalLockEnabled = true
        disableOuterBounceEnabled = true
        delayContentTouchesEnabled = false
        showVerticalScrollIndicatorEnabled = true
        showHorizontalScrollIndicatorEnabled = false
    }

    private func configureFollowDefaults() {
        followLatestEnabled = true
        startFollowingLatestEnabled = true
        followIntervalMilliseconds = 500
        nearBottomThresholdPoints = 80
        upwardScrollThresholdPoints = 4
        programmaticScrollGuardMilliseconds = 250
        maximumFollowDurationSeconds = 0
    }

    private func configureTargetDefaults() {
        rescanMissingTargetEnabled = true
        includeDocumentRootsEnabled = true
        preferConversationContainerEnabled = true
        targetMinimumHeightPoints = 160
        targetMinimumScrollRangePoints = 40
    }

    private func clearRenderingPressureOptions() {
        useContentVisibilityEnabled = false
        useCSSContainmentEnabled = false
        deferOffscreenImagesEnabled = false
        pauseOffscreenMediaEnabled = false
        hideEmbeddedFramesEnabled = false
        hideCanvasEnabled = false
        disableAnimationsEnabled = false
        reduceVisualEffectsEnabled = false
        hideSidebarEnabled = false
        hideHeaderEnabled = false
        optimizeCodeBlocksEnabled = false
        maximumImageHeightPoints = 0
        domOptimizationIntervalMilliseconds = 2500
        diagnosticsEnabled = false
        logTargetSelectionEnabled = false
        logDOMCountsEnabled = false
    }
}
