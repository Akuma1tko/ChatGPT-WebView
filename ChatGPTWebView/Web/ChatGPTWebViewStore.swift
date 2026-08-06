import Foundation
import UIKit
import WebKit

@MainActor
final class ChatGPTWebViewStore: ObservableObject {
    let provider: AIProvider
    let webView: WKWebView
    let coordinator: SecureChatGPTWebViewCoordinator

    private struct CapturedBrowserState: Decodable {
        let origin: String
        let localStorage: [String: String]
        let lastURL: String
    }

    private let startURL: URL
    private let initialURL: URL
    private let profile: ChatGPTProfile
    private let storageProfileID: String
    private let cookieVault: ChatGPTProfileCookieVault
    private let browserStateVault: ChatGPTProfileBrowserStateVault
    private let onDetectedDisplayName: (String, String) -> Void
    private var didPrepareInitialLoad = false
    private var didDetectDisplayName = false
    private var explicitLogoutDetected = false
    private var typingPriorityActive = false
    private var captureDeferredForTyping = false
    private var sessionMutationGeneration = 0
    private var navigationGeneration = 0
    private var logoutNavigationGeneration: Int?
    private var delayedCaptureTask: Task<Void, Never>?

    init(
        provider: AIProvider = AIProviderID.chatGPT.provider,
        initialURL: URL? = nil,
        profile: ChatGPTProfile = ChatGPTProfile(
            id: ChatGPTProfile.primaryID,
            displayName: "Current User",
            kind: .primary
        ),
        cookieVault: ChatGPTProfileCookieVault = ChatGPTProfileCookieVault(),
        browserStateVault: ChatGPTProfileBrowserStateVault = ChatGPTProfileBrowserStateVault(),
        onDetectedDisplayName: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.provider = provider
        self.startURL = provider.startURL
        self.profile = profile
        self.storageProfileID = profile.storageID(for: provider.id)
        self.cookieVault = cookieVault
        self.browserStateVault = browserStateVault
        self.onDetectedDisplayName = onDetectedDisplayName

        if provider.id == .chatGPT, profile.kind != .guest {
            cookieVault.migrateLegacyProfileIfNeeded(
                legacyProfileID: profile.id,
                profileID: storageProfileID
            )
            browserStateVault.migrateLegacyProfileIfNeeded(
                legacyProfileID: profile.id,
                profileID: storageProfileID
            )
        }

        self.coordinator = SecureChatGPTWebViewCoordinator(provider: provider)

        let isPersistentProfile = profile.kind != .guest
        let shouldRestorePersistentSession = !isPersistentProfile
            || browserStateVault.shouldRestoreSession(profileID: storageProfileID)
        self.explicitLogoutDetected = isPersistentProfile && !shouldRestorePersistentSession
        self.logoutNavigationGeneration = self.explicitLogoutDetected ? 0 : nil

        let restoredURL = isPersistentProfile && shouldRestorePersistentSession
            ? browserStateVault.lastURL(
                profileID: storageProfileID,
                allowedHostSuffixes: provider.authenticatedHostSuffixes
            )
            : nil
        self.initialURL = restoredURL ?? initialURL ?? provider.startURL

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.kind == .primary ? .default() : .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        if provider.id == .claude || provider.id == .grok || provider.id == .deepSeek {
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        }

        if isPersistentProfile {
            configuration.userContentController.add(
                coordinator,
                name: SecureChatGPTWebViewCoordinator.profileLogoutMessageName
            )
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.persistentProfileLogoutDetectionScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )

            if shouldRestorePersistentSession,
               let restoreScript = browserStateVault.documentStartRestoreScript(
                profileID: storageProfileID,
                overwriteExistingValues: profile.kind == .saved
               ) {
                configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: restoreScript,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true
                    )
                )
            }
        }

        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        self.webView = webView

        coordinator.providerAuthenticationDidCompleteHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleProviderAuthenticationConfirmed()
            }
        }
        coordinator.attachMainWebView(webView)

        coordinator.navigationDidFinishHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.navigationGeneration += 1
                self.scheduleProfileStateCapture()
            }
        }
        coordinator.logoutDetectedHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleExplicitLogoutDetected()
            }
        }
    }

    func loadIfNeeded() {
        guard webView.url == nil, !webView.isLoading else {
            return
        }

        guard !didPrepareInitialLoad else {
            webView.load(URLRequest(url: startURL))
            return
        }

        didPrepareInitialLoad = true

        if profile.kind != .guest {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.restorePersistentProfileCookies()
                guard self.webView.url == nil, !self.webView.isLoading else { return }
                self.webView.load(URLRequest(url: self.initialURL))
            }
        } else {
            webView.load(URLRequest(url: initialURL))
        }
    }

    func stopCurrentActivity() {
        webView.stopLoading()
    }

    func reloadCurrentSession() {
        if webView.isLoading {
            webView.stopLoading()
        }

        if webView.url == nil {
            loadIfNeeded()
        } else {
            webView.reload()
        }
    }

    func startNewChat() {
        if webView.isLoading {
            webView.stopLoading()
        }
        webView.load(URLRequest(url: startURL))
    }

    func setTypingPriority(_ isTyping: Bool) {
        guard typingPriorityActive != isTyping else { return }
        typingPriorityActive = isTyping

        if isTyping {
            if delayedCaptureTask != nil {
                captureDeferredForTyping = true
            }
            delayedCaptureTask?.cancel()
            delayedCaptureTask = nil
            return
        }

        if captureDeferredForTyping {
            captureDeferredForTyping = false
            scheduleProfileStateCapture()
        }
    }

    func persistProfileSession() async {
        await captureProfileState(force: true)
    }

    func removeSavedProfileSession() async {
        guard profile.kind == .saved else { return }

        sessionMutationGeneration += 1
        explicitLogoutDetected = true
        logoutNavigationGeneration = navigationGeneration
        captureDeferredForTyping = false
        delayedCaptureTask?.cancel()
        delayedCaptureTask = nil
        webView.stopLoading()
        cookieVault.delete(profileID: storageProfileID)
        browserStateVault.delete(profileID: storageProfileID)

        if provider.id == .chatGPT {
            cookieVault.delete(profileID: profile.id)
            browserStateVault.delete(profileID: profile.id)
        }

        await removeAllWebsiteData()
    }

    func resetGuestSession() async {
        guard profile.kind == .guest else { return }

        webView.stopLoading()
        await removeAllWebsiteData()
        didPrepareInitialLoad = true
        webView.load(URLRequest(url: startURL))
    }

    private func handleProviderAuthenticationConfirmed() {
        explicitLogoutDetected = false
        logoutNavigationGeneration = nil
        didDetectDisplayName = false

        if profile.kind != .guest {
            sessionMutationGeneration += 1
            browserStateVault.markActive(profileID: storageProfileID)
        }

        scheduleProfileStateCapture()
    }

    private func handleExplicitLogoutDetected() {
        guard profile.kind != .guest else { return }

        sessionMutationGeneration += 1
        explicitLogoutDetected = true
        logoutNavigationGeneration = navigationGeneration
        didDetectDisplayName = false
        captureDeferredForTyping = false
        delayedCaptureTask?.cancel()
        delayedCaptureTask = nil
        cookieVault.delete(profileID: storageProfileID)
        browserStateVault.markLoggedOut(profileID: storageProfileID)
    }

    private func scheduleProfileStateCapture() {
        delayedCaptureTask?.cancel()

        guard !typingPriorityActive else {
            captureDeferredForTyping = true
            delayedCaptureTask = nil
            return
        }

        delayedCaptureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }

            guard !self.typingPriorityActive else {
                self.captureDeferredForTyping = true
                return
            }

            await self.captureProfileState(force: false)
        }
    }

    private func captureProfileState(force: Bool) async {
        if typingPriorityActive && !force {
            captureDeferredForTyping = true
            return
        }

        var detectedDisplayName: String?
        if !didDetectDisplayName || explicitLogoutDetected {
            detectedDisplayName = await detectCurrentAccountDisplayName()
        }

        if explicitLogoutDetected {
            let logoutGeneration = logoutNavigationGeneration ?? navigationGeneration
            guard navigationGeneration > logoutGeneration,
                  provider.isAuthenticatedContentURL(webView.url),
                  let detectedDisplayName,
                  !detectedDisplayName.isEmpty else {
                cookieVault.delete(profileID: storageProfileID)
                browserStateVault.markLoggedOut(profileID: storageProfileID)
                return
            }

            sessionMutationGeneration += 1
            browserStateVault.markActive(profileID: storageProfileID)
            explicitLogoutDetected = false
            logoutNavigationGeneration = nil
            didDetectDisplayName = true
            onDetectedDisplayName(profile.id, detectedDisplayName)
        }

        let captureGeneration = sessionMutationGeneration

        if profile.kind != .guest {
            let cookies = await providerCookies()
            guard captureGeneration == sessionMutationGeneration, !explicitLogoutDetected else {
                return
            }

            let browserState = await captureCurrentBrowserState()
            guard captureGeneration == sessionMutationGeneration, !explicitLogoutDetected else {
                return
            }

            cookieVault.save(cookies, profileID: storageProfileID)
            if let browserState {
                browserStateVault.save(
                    origin: browserState.origin,
                    localStorage: browserState.localStorage,
                    lastURL: provider.isAuthenticatedContentURL(webView.url)
                        ? browserState.lastURL
                        : nil,
                    profileID: storageProfileID
                )
            }
        }

        guard profile.kind != .guest, !didDetectDisplayName else {
            return
        }

        let displayName: String?
        if let detectedDisplayName {
            displayName = detectedDisplayName
        } else {
            displayName = await detectCurrentAccountDisplayName()
        }

        guard let displayName, !displayName.isEmpty else {
            return
        }

        didDetectDisplayName = true
        onDetectedDisplayName(profile.id, displayName)
    }

    private func restorePersistentProfileCookies() async {
        guard browserStateVault.shouldRestoreSession(profileID: storageProfileID) else {
            return
        }

        let existingCookies = await providerCookies()
        let existingCookieIDs = Set(existingCookies.map(cookieIdentity))
        let savedCookies = cookieVault.load(profileID: storageProfileID)
            .filter(isProviderCookie)

        for cookie in savedCookies where !existingCookieIDs.contains(cookieIdentity(cookie)) {
            await setCookie(cookie)
        }
    }

    private func providerCookies() async -> [HTTPCookie] {
        await allCookies().filter(isProviderCookie)
    }

    private func isProviderCookie(_ cookie: HTTPCookie) -> Bool {
        let host = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return provider.persistentCookieHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    private func cookieIdentity(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)\u{0}\(cookie.domain.lowercased())\u{0}\(cookie.path)"
    }

    private func captureCurrentBrowserState() async -> CapturedBrowserState? {
        let script = #"""
        (() => {
          const values = {};
          try {
            for (let index = 0; index < window.localStorage.length; index++) {
              const key = window.localStorage.key(index);
              if (key === null) continue;
              const value = window.localStorage.getItem(key);
              if (value !== null) values[key] = value;
            }
          } catch (_) {}

          return JSON.stringify({
            origin: window.location.origin || '',
            localStorage: values,
            lastURL: window.location.href || ''
          });
        })();
        """#

        guard let raw = await evaluateJavaScript(script) as? String,
              let data = raw.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CapturedBrowserState.self, from: data)
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private func removeAllWebsiteData() async {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private func detectCurrentAccountDisplayName() async -> String? {
        let script = #"""
        (() => {
          const clean = (value) => String(value || '')
            .replace(/\s+/g, ' ')
            .trim();
          const emailPattern = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;
          const candidates = Array.from(document.querySelectorAll(
            'button,[role="button"],[aria-label],[title],[data-testid]'
          ));

          const values = [];
          for (const element of candidates) {
            const label = clean([
              element.getAttribute('aria-label'),
              element.getAttribute('title'),
              element.innerText,
              element.textContent
            ].filter(Boolean).join(' '));
            if (label) values.push(label);
          }

          for (const value of values) {
            const email = value.match(emailPattern);
            if (email) return email[0];
          }

          for (const element of candidates) {
            const metadata = clean([
              element.getAttribute('aria-label'),
              element.getAttribute('title'),
              element.getAttribute('data-testid')
            ].filter(Boolean).join(' ')).toLowerCase();
            if (!metadata.includes('profile') && !metadata.includes('account') && !metadata.includes('user')) continue;

            const text = clean(element.innerText || element.textContent || '');
            if (!text || text.length > 80) continue;
            if (/^(profile|account|user|menu|open profile menu)$/i.test(text)) continue;
            return text;
          }

          return '';
        })();
        """#

        return await evaluateJavaScript(script) as? String
    }

    private func evaluateJavaScript(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    private static let persistentProfileLogoutDetectionScript = #"""
    (() => {
      const normalize = (value) => String(value || '')
        .replace(/\s+/g, ' ')
        .trim()
        .toLowerCase();

      document.addEventListener('click', (event) => {
        const target = event.target instanceof Element
          ? event.target.closest('button,a,[role="menuitem"],[role="button"]')
          : null;
        if (!target) return;

        const labels = [
          target.innerText,
          target.textContent,
          target.getAttribute('aria-label'),
          target.getAttribute('title')
        ].filter(Boolean).map(normalize);

        if (!labels.some((label) => /^(log\s*out|logout|sign\s*out)$/.test(label))) return;
        try {
          window.webkit.messageHandlers.chatGPTProfileLogout.postMessage('logout');
        } catch (_) {}
      }, true);
    })();
    """#
}

final class SecureChatGPTWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver {
    static let profileLogoutMessageName = "chatGPTProfileLogout"

    var navigationDidFinishHandler: ((WKWebView) -> Void)?
    var logoutDetectedHandler: (() -> Void)?
    var providerAuthenticationDidCompleteHandler: (() -> Void)?

    private let provider: AIProvider
    private let allowedHostSuffixes: [String]
    private weak var mainWebView: WKWebView?
    private weak var observedCookieStore: WKHTTPCookieStore?
    private var authPopupWebViews: [ObjectIdentifier: WKWebView] = [:]
    private var grokAuthInProgress = false
    private var grokAuthLeftProvider = false
    private var grokAuthBridgeReloadRequested = false
    private var grokIntendedURL: URL?
    private var claudeSessionCookieSeen = false
    private let internalSchemes = [
        "https",
        "about",
        "blob",
        "data"
    ]
    private let externalSchemes = [
        "http",
        "https",
        "mailto",
        "tel",
        "sms"
    ]

    init(provider: AIProvider = AIProviderID.chatGPT.provider) {
        self.provider = provider
        self.allowedHostSuffixes = provider.allowedHostSuffixes
        super.init()
    }

    deinit {
        observedCookieStore?.remove(self)
    }

    func attachMainWebView(_ webView: WKWebView) {
        mainWebView = webView

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        if observedCookieStore !== cookieStore {
            observedCookieStore?.remove(self)
            observedCookieStore = cookieStore
            cookieStore.add(self)
        }

        if provider.id == .claude {
            inspectClaudeSessionCookie(in: cookieStore)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.profileLogoutMessageName else { return }
        logoutDetectedHandler?()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard provider.id == .claude else { return }
        inspectClaudeSessionCookie(in: cookieStore)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if provider.id == .grok {
            updateGrokAuthState(for: webView.url)

            if grokAuthInProgress, isGrokAuthBridgeCompletionURL(webView.url) {
                reloadGrokAfterAuthBridgeIfNeeded()
                return
            }

            if grokAuthInProgress,
               grokAuthLeftProvider,
               isCompletedGrokReturnURL(webView.url) {
                grokAuthInProgress = false
                grokAuthLeftProvider = false
                grokAuthBridgeReloadRequested = false
                providerAuthenticationDidCompleteHandler?()
            }
        }

        if isAuthPopup(webView) {
            return
        }

        navigationDidFinishHandler?(webView)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if provider.id == .grok {
            updateGrokAuthState(for: url)

            if navigationAction.targetFrame == nil,
               isAllowedInsideWebView(url: url) {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
        }

        if isAuthPopup(webView) {
            decisionHandler(allowsAuthPopupURL(url) ? .allow : .cancel)
            return
        }

        if navigationAction.targetFrame == nil,
           shouldUseProviderAuthPopup(url: url, openerURL: webView.url) {
            decisionHandler(.allow)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(allowsEmbeddedFrameURL(url) ? .allow : .cancel)
            return
        }

        if isAllowedInsideWebView(url: url) {
            decisionHandler(.allow)
            return
        }

        if shouldOpenExternally(url: url, navigationAction: navigationAction) {
            openExternally(url)
        }

        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else {
            return nil
        }

        // Keep Grok OAuth/new-window navigation in one provider WebView.
        // The Google -> xAI -> Grok cookie bridge must remain in one browsing context.
        if provider.id == .grok, isAllowedInsideWebView(url: url) {
            updateGrokAuthState(for: url)
            webView.load(URLRequest(url: url))
            return nil
        }

        // Claude keeps its dedicated auth popup flow.
        if isAuthPopup(webView) {
            webView.load(URLRequest(url: url))
            return nil
        }

        if shouldUseProviderAuthPopup(url: url, openerURL: webView.url) {
            return createAuthPopupWebView(configuration: configuration, opener: webView, initialURL: url)
        }

        if isAllowedInsideWebView(url: url) {
            webView.load(URLRequest(url: url))
        } else if shouldOpenExternally(url: url, navigationAction: navigationAction) {
            openExternally(url)
        }

        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard isAuthPopup(webView) else { return }
        closeAuthPopup(webView)
    }

    private func createAuthPopupWebView(
        configuration: WKWebViewConfiguration,
        opener: WKWebView,
        initialURL: URL
    ) -> WKWebView {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let popupWebView = WKWebView(frame: .zero, configuration: configuration)
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        popupWebView.allowsBackForwardNavigationGestures = true
        popupWebView.scrollView.keyboardDismissMode = .interactive
        popupWebView.customUserAgent = opener.customUserAgent
        popupWebView.backgroundColor = .systemBackground
        popupWebView.isOpaque = true

        let sourceView = mainWebView ?? opener
        let hostView = sourceView.superview ?? sourceView
        if hostView === sourceView {
            popupWebView.frame = sourceView.bounds
        } else {
            popupWebView.frame = sourceView.convert(sourceView.bounds, to: hostView)
        }
        popupWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        popupWebView.layer.zPosition = 999
        hostView.addSubview(popupWebView)

        let popupID = ObjectIdentifier(popupWebView)
        authPopupWebViews[popupID] = popupWebView

        return popupWebView
    }

    private func closeAuthPopup(_ webView: WKWebView) {
        let popupID = ObjectIdentifier(webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        authPopupWebViews.removeValue(forKey: popupID)
    }

    private func updateGrokAuthState(for url: URL?) {
        guard provider.id == .grok, let url else { return }

        if isGrokAuthFlowURL(url) {
            if !grokAuthInProgress {
                grokAuthBridgeReloadRequested = false
                grokAuthLeftProvider = false

                if let currentURL = mainWebView?.url,
                   isCompletedGrokReturnURL(currentURL) {
                    grokIntendedURL = currentURL
                } else {
                    grokIntendedURL = provider.startURL
                }
            }

            grokAuthInProgress = true
            if !isGrokURL(url) {
                grokAuthLeftProvider = true
            }
            return
        }

        if !grokAuthInProgress, isCompletedGrokReturnURL(url) {
            grokIntendedURL = url
        }
    }

    private func isGrokAuthFlowURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }

        let path = url.path.lowercased()
        if isGrokURL(url) {
            return path.hasPrefix("/sign-in")
                || path.hasPrefix("/signin")
                || path.hasPrefix("/login")
                || path.hasPrefix("/auth")
                || path.hasPrefix("/api/auth")
                || path.hasPrefix("/oauth")
                || path.hasPrefix("/session")
                || path.hasPrefix("/callback")
        }

        if hostMatches(host, suffixes: ["x.com", "twitter.com"]) {
            return path.hasPrefix("/i/flow")
                || path.hasPrefix("/i/oauth2")
                || path.hasPrefix("/oauth")
                || path.hasPrefix("/login")
                || path.hasPrefix("/signup")
                || path.hasPrefix("/account/")
        }

        return hostMatches(
            host,
            suffixes: [
                "x.ai",
                "auth.grokipedia.com",
                "auth.grokusercontent.com",
                "accounts.google.com",
                "accounts.youtube.com",
                "id.google.com",
                "appleid.apple.com",
                "login.apple.com",
                "signin.apple.com",
                "challenges.cloudflare.com"
            ]
        )
    }

    private func isGrokAuthBridgeCompletionURL(_ url: URL?) -> Bool {
        guard grokAuthInProgress,
              let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              hostMatches(
                host,
                suffixes: [
                    "accounts.x.ai",
                    "auth.grokipedia.com",
                    "auth.grokusercontent.com"
                ]
              ) else {
            return false
        }

        let path = url.path.lowercased()
        return path.hasPrefix("/set-cookie")
            || path.hasPrefix("/set-session")
            || path.hasPrefix("/success")
            || path.hasPrefix("/complete")
            || path.hasPrefix("/continue")
            || path.hasPrefix("/verify")
            || path.hasPrefix("/exchange-token")
            || path.hasPrefix("/callback")
            || path.hasPrefix("/auth/callback")
            || path.hasPrefix("/oauth/callback")
            || path.hasPrefix("/check-login")
    }

    private func reloadGrokAfterAuthBridgeIfNeeded() {
        guard provider.id == .grok,
              grokAuthInProgress,
              !grokAuthBridgeReloadRequested,
              let mainWebView else {
            return
        }

        grokAuthBridgeReloadRequested = true
        let targetURL = grokIntendedURL ?? provider.startURL
        mainWebView.stopLoading()
        mainWebView.load(URLRequest(url: targetURL))
    }

    private func hostMatches(_ host: String, suffixes: [String]) -> Bool {
        suffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    private func completeProviderAuthentication() {
        providerAuthenticationDidCompleteHandler?()

        guard let mainWebView else { return }
        mainWebView.stopLoading()
        mainWebView.load(URLRequest(url: provider.startURL))
    }

    private func inspectClaudeSessionCookie(in cookieStore: WKHTTPCookieStore) {
        guard provider.id == .claude, !claudeSessionCookieSeen else { return }

        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }

            let hasClaudeSession = cookies.contains { cookie in
                let domain = cookie.domain
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
                return cookie.name == "sessionKey"
                    && (domain == "claude.ai" || domain.hasSuffix(".claude.ai"))
                    && cookie.value.hasPrefix("sk-ant-sid01")
            }

            guard hasClaudeSession else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.claudeSessionCookieSeen else { return }
                self.claudeSessionCookieSeen = true

                let popups = Array(self.authPopupWebViews.values)
                for popup in popups {
                    self.closeAuthPopup(popup)
                }

                self.completeProviderAuthentication()
            }
        }
    }

    private func shouldUseProviderAuthPopup(url: URL, openerURL: URL?) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let openerPath = openerURL?.path.lowercased() ?? ""

        switch provider.id {
        case .claude:
            let authHost = host == "accounts.google.com"
                || host == "appleid.apple.com"
                || host == "login.microsoftonline.com"
                || host == "accounts.anthropic.com"
                || host.hasSuffix(".workos.com")
                || host.hasSuffix(".auth0.com")
            return authHost || openerPath.hasPrefix("/login") || openerPath.hasPrefix("/auth")

        case .grok:
            return false

        default:
            return false
        }
    }

    private func isCompletedGrokReturnURL(_ url: URL?) -> Bool {
        guard let url, isGrokURL(url) else { return false }
        let path = url.path.lowercased()
        return !path.hasPrefix("/sign-in")
            && !path.hasPrefix("/signin")
            && !path.hasPrefix("/login")
            && !path.hasPrefix("/auth")
    }

    private func isGrokURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "grok.com" || host.hasSuffix(".grok.com")
    }

    private func isAuthPopup(_ webView: WKWebView) -> Bool {
        authPopupWebViews[ObjectIdentifier(webView)] != nil
    }

    private func allowsAuthPopupURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http"
            || scheme == "https"
            || scheme == "about"
            || scheme == "blob"
            || scheme == "data"
    }

    private func allowsEmbeddedFrameURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https"
            || scheme == "about"
            || scheme == "blob"
            || scheme == "data"
    }

    private func isAllowedInsideWebView(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), internalSchemes.contains(scheme) else {
            return false
        }

        if scheme == "about" || scheme == "blob" || scheme == "data" {
            return true
        }

        guard scheme == "https", let host = url.host?.lowercased() else {
            return false
        }

        return allowedHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    private func shouldOpenExternally(url: URL, navigationAction: WKNavigationAction) -> Bool {
        guard let scheme = url.scheme?.lowercased(), externalSchemes.contains(scheme) else {
            return false
        }

        if isAllowedInsideWebView(url: url) {
            return false
        }

        return navigationAction.navigationType == .linkActivated
    }

    private func openExternally(_ url: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}
