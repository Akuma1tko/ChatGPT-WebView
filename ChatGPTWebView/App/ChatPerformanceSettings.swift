import Combine
import Foundation

struct ChatPerformanceConfiguration: Equatable {
    let isEnabled: Bool
    let visibleMessageLimit: Int
    let latestExchangeOnly: Bool
    let enabledProviderIDs: Set<AIProviderID>
    let chatGPTMobileWebFallbackEnabled: Bool

    static let disabled = ChatPerformanceConfiguration(
        isEnabled: false,
        visibleMessageLimit: 5,
        latestExchangeOnly: false,
        enabledProviderIDs: [],
        chatGPTMobileWebFallbackEnabled: false
    )

    func isEnabled(for providerID: AIProviderID) -> Bool {
        isEnabled && !latestExchangeOnly && enabledProviderIDs.contains(providerID)
    }

    func isLatestExchangeOnlyEnabled(for providerID: AIProviderID) -> Bool {
        latestExchangeOnly && enabledProviderIDs.contains(providerID)
    }
}

@MainActor
final class ChatPerformanceSettings: ObservableObject {
    static let visibleMessageRange = 5...100
    static let visibleMessageStep = 5
    static let messagesPerRenderBucket = 5

    static let progressiveAccessBucketRange = 1...12
    static let defaultProgressiveAccessBucketCount = 6
    static let defaultVisibleMessageLimit = 5
    static let defaultEnabledProviderIDs: Set<AIProviderID> = [.chatGPT, .claude]

    static let progressiveAccessSettingsDidChangeNotification = Notification.Name(
        "ContextPortProgressiveAccessSettingsDidChange"
    )

    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    @Published var visibleMessageLimit: Int {
        didSet {
            let normalized = Self.normalizedVisibleMessageLimit(visibleMessageLimit)
            if visibleMessageLimit != normalized {
                visibleMessageLimit = normalized
                return
            }
            userDefaults.set(visibleMessageLimit, forKey: Self.visibleMessageLimitKey)
        }
    }

    @Published var latestExchangeOnly: Bool {
        didSet {
            userDefaults.set(latestExchangeOnly, forKey: Self.latestExchangeOnlyKey)
            if latestExchangeOnly, isEnabled {
                isEnabled = false
            }
        }
    }

    @Published private(set) var enabledProviderIDs: Set<AIProviderID> {
        didSet {
            let values = enabledProviderIDs.map(\.rawValue).sorted()
            userDefaults.set(values, forKey: Self.enabledProviderIDsKey)
        }
    }

    @Published var chatGPTMobileWebFallbackEnabled: Bool {
        didSet {
            userDefaults.set(
                chatGPTMobileWebFallbackEnabled,
                forKey: Self.chatGPTMobileWebFallbackEnabledKey
            )
        }
    }

    @Published var progressiveChatAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                progressiveChatAccessEnabled,
                forKey: Self.progressiveChatAccessEnabledKey
            )
            postProgressiveAccessSettingsDidChange()
        }
    }

    @Published var progressiveAccessBucketCount: Int {
        didSet {
            let normalized = Self.normalizedProgressiveAccessBucketCount(
                progressiveAccessBucketCount
            )
            if progressiveAccessBucketCount != normalized {
                progressiveAccessBucketCount = normalized
                return
            }
            userDefaults.set(
                progressiveAccessBucketCount,
                forKey: Self.progressiveAccessBucketCountKey
            )
            postProgressiveAccessSettingsDidChange()
        }
    }

    private static let enabledKey = "ChatPerformanceEnabled"
    private static let visibleMessageLimitKey = "ChatPerformanceVisibleMessageLimit"
    private static let latestExchangeOnlyKey = "ChatPerformanceLatestExchangeOnly"
    private static let enabledProviderIDsKey = "ChatPerformanceEnabledProviderIDs"
    private static let chatGPTMobileWebFallbackEnabledKey = "ChatGPTMobileWebFallbackEnabled"
    private static let progressiveChatAccessEnabledKey = "ProgressiveChatAccessEnabled"
    private static let progressiveAccessBucketCountKey = "ProgressiveChatAccessBucketCount"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if userDefaults.object(forKey: Self.enabledKey) == nil {
            self.isEnabled = false
        } else {
            self.isEnabled = userDefaults.bool(forKey: Self.enabledKey)
        }

        let storedLimit = userDefaults.integer(forKey: Self.visibleMessageLimitKey)
        self.visibleMessageLimit = Self.normalizedVisibleMessageLimit(
            storedLimit == 0 ? Self.defaultVisibleMessageLimit : storedLimit
        )
        self.latestExchangeOnly = userDefaults.bool(forKey: Self.latestExchangeOnlyKey)

        if let storedProviderIDs = userDefaults.stringArray(forKey: Self.enabledProviderIDsKey) {
            self.enabledProviderIDs = Set(storedProviderIDs.compactMap(AIProviderID.init(rawValue:)))
        } else {
            self.enabledProviderIDs = Self.defaultEnabledProviderIDs
        }

        self.chatGPTMobileWebFallbackEnabled = userDefaults.bool(
            forKey: Self.chatGPTMobileWebFallbackEnabledKey
        )

        if userDefaults.object(forKey: Self.progressiveChatAccessEnabledKey) == nil {
            self.progressiveChatAccessEnabled = true
        } else {
            self.progressiveChatAccessEnabled = userDefaults.bool(
                forKey: Self.progressiveChatAccessEnabledKey
            )
        }

        let storedBucketCount = userDefaults.integer(
            forKey: Self.progressiveAccessBucketCountKey
        )
        self.progressiveAccessBucketCount = Self.normalizedProgressiveAccessBucketCount(
            storedBucketCount == 0
                ? Self.defaultProgressiveAccessBucketCount
                : storedBucketCount
        )
    }

    var configuration: ChatPerformanceConfiguration {
        ChatPerformanceConfiguration(
            isEnabled: isEnabled,
            visibleMessageLimit: visibleMessageLimit,
            latestExchangeOnly: latestExchangeOnly,
            enabledProviderIDs: enabledProviderIDs,
            chatGPTMobileWebFallbackEnabled: chatGPTMobileWebFallbackEnabled
        )
    }

    var renderBucketCount: Int {
        max(1, visibleMessageLimit / Self.messagesPerRenderBucket)
    }

    func setRenderBucketCount(_ bucketCount: Int) {
        let maximumBuckets = Self.visibleMessageRange.upperBound / Self.messagesPerRenderBucket
        let normalized = min(max(bucketCount, 1), maximumBuckets)
        visibleMessageLimit = normalized * Self.messagesPerRenderBucket
    }

    func isProviderEnabled(_ providerID: AIProviderID) -> Bool {
        enabledProviderIDs.contains(providerID)
    }

    func setProviderEnabled(_ providerID: AIProviderID, enabled: Bool) {
        if enabled {
            enabledProviderIDs.insert(providerID)
        } else {
            enabledProviderIDs.remove(providerID)
        }
    }

    func resetToFactoryOptimizationDefaults() {
        latestExchangeOnly = false
        isEnabled = false
        visibleMessageLimit = Self.defaultVisibleMessageLimit
        enabledProviderIDs = Self.defaultEnabledProviderIDs
        chatGPTMobileWebFallbackEnabled = false
        progressiveChatAccessEnabled = true
        progressiveAccessBucketCount = Self.defaultProgressiveAccessBucketCount
        postProgressiveAccessSettingsDidChange()
    }

    private func postProgressiveAccessSettingsDidChange() {
        NotificationCenter.default.post(
            name: Self.progressiveAccessSettingsDidChangeNotification,
            object: nil
        )
    }

    private static func normalizedVisibleMessageLimit(_ value: Int) -> Int {
        let clamped = min(max(value, visibleMessageRange.lowerBound), visibleMessageRange.upperBound)
        let step = visibleMessageStep
        return Int((Double(clamped) / Double(step)).rounded()) * step
    }

    private static func normalizedProgressiveAccessBucketCount(_ value: Int) -> Int {
        min(
            max(value, progressiveAccessBucketRange.lowerBound),
            progressiveAccessBucketRange.upperBound
        )
    }
}
