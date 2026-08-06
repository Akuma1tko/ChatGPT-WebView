import SwiftUI

@main
struct ChatGPTWebViewApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var updateChecker = AppUpdateChecker()
    @StateObject private var providerManager = AIProviderManager()
    @StateObject private var profileManager = ChatGPTProfileManager()
    @StateObject private var profileSessionPool = ChatGPTProfileSessionPool()
    @StateObject private var memoryLaunchSettings = MemoryLaunchSettings()
    @StateObject private var chatPerformanceSettings = ChatPerformanceSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(updateChecker)
                .environmentObject(providerManager)
                .environmentObject(profileManager)
                .environmentObject(profileSessionPool)
                .environmentObject(memoryLaunchSettings)
                .environmentObject(chatPerformanceSettings)
                .onAppear {
                    profileSessionPool.updateChatPerformanceConfiguration(
                        chatPerformanceSettings.configuration
                    )
                }
                .onChange(of: chatPerformanceSettings.configuration) { configuration in
                    profileSessionPool.updateChatPerformanceConfiguration(configuration)
                }
                .task {
                    await appModel.restoreSession()
                }
                .task {
                    await updateChecker.checkForUpdateOnStartup()
                }
                .onOpenURL { url in
                    appModel.handleOpenURL(url)
                }
        }
    }
}
