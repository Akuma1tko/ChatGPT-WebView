import Foundation
import WebKit

private final class ChatGPTMobileFallbackState: NSObject {
    var isEnabled = false
    var isScriptInstalled = false
    var bridge: ChatGPTMobileFallbackScriptBridge?
}

private final class ChatGPTMobileFallbackScriptBridge: NSObject, WKScriptMessageHandler {
    weak var store: ChatGPTWebViewStore?

    init(store: ChatGPTWebViewStore) {
        self.store = store
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == ChatGPTWebViewStore.chatGPTMobileFallbackReadyMessageName else {
            return
        }

        let store = self.store
        Task { @MainActor in
            store?.applyChatGPTMobileWebFallbackToPage()
        }
    }
}

@MainActor
private final class ChatGPTMobileFallbackRegistry {
    static let shared = ChatGPTMobileFallbackRegistry()

    private let states = NSMapTable<ChatGPTWebViewStore, ChatGPTMobileFallbackState>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    func state(for store: ChatGPTWebViewStore) -> ChatGPTMobileFallbackState {
        if let existing = states.object(forKey: store) {
            return existing
        }

        let state = ChatGPTMobileFallbackState()
        states.setObject(state, forKey: store)
        return state
    }
}

@MainActor
extension ChatGPTWebViewStore {
    static let chatGPTMobileFallbackReadyMessageName = "contextPortChatGPTMobileFallbackReady"

    func updateChatGPTMobileWebFallback(_ isEnabled: Bool) {
        guard provider.id == .chatGPT else { return }

        let state = ChatGPTMobileFallbackRegistry.shared.state(for: self)
        state.isEnabled = isEnabled
        installChatGPTMobileFallbackScriptIfNeeded(state: state)
        applyChatGPTMobileWebFallbackToPage()
    }

    func applyChatGPTMobileWebFallbackToPage() {
        guard provider.id == .chatGPT else { return }

        let state = ChatGPTMobileFallbackRegistry.shared.state(for: self)
        let enabledLiteral = state.isEnabled ? "true" : "false"
        let script = #"""
        (() => {
          const enabledKey = 'contextport_chatgpt_mweb_fallback_enabled';
          const ownedURLKey = 'contextport_chatgpt_mweb_fallback_owned_url';

          const isConversationURL = (value) => {
            try {
              const url = new URL(value, location.href);
              const host = url.hostname.toLowerCase();
              if (host !== 'chatgpt.com' && !host.endsWith('.chatgpt.com')) return false;
              const components = url.pathname.split('/').filter(Boolean);
              const conversationIndex = components.indexOf('c');
              return conversationIndex >= 0 && conversationIndex < components.length - 1;
            } catch (_) {
              return false;
            }
          };

          const urlWithoutFallback = (value) => {
            const url = new URL(value, location.href);
            url.searchParams.delete('mweb_fallback');
            return url.toString();
          };

          try {
            localStorage.setItem(enabledKey, '\#(enabledLiteral)');
          } catch (_) {}

          if (!isConversationURL(location.href)) return false;

          const currentURL = new URL(location.href);
          const currentBaseURL = urlWithoutFallback(currentURL.toString());
          let ownedURL = '';
          try {
            ownedURL = sessionStorage.getItem(ownedURLKey) || '';
          } catch (_) {}

          if (\#(enabledLiteral)) {
            if (!currentURL.searchParams.has('mweb_fallback')) {
              try {
                sessionStorage.setItem(ownedURLKey, currentBaseURL);
              } catch (_) {}
              currentURL.searchParams.set('mweb_fallback', '1');
              location.replace(currentURL.toString());
              return true;
            }
            return false;
          }

          if (ownedURL === currentBaseURL && currentURL.searchParams.get('mweb_fallback') === '1') {
            try {
              sessionStorage.removeItem(ownedURLKey);
            } catch (_) {}
            currentURL.searchParams.delete('mweb_fallback');
            location.replace(currentURL.toString());
            return true;
          }

          return false;
        })();
        """#

        webView.evaluateJavaScript(script) { _, _ in }
    }

    private func installChatGPTMobileFallbackScriptIfNeeded(state: ChatGPTMobileFallbackState) {
        guard !state.isScriptInstalled else { return }

        let bridge = ChatGPTMobileFallbackScriptBridge(store: self)
        let controller = webView.configuration.userContentController
        controller.add(bridge, name: Self.chatGPTMobileFallbackReadyMessageName)
        controller.addUserScript(
            WKUserScript(
                source: Self.chatGPTMobileFallbackDocumentStartScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        controller.addUserScript(
            WKUserScript(
                source: Self.chatGPTMobileFallbackReadyScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        state.bridge = bridge
        state.isScriptInstalled = true
    }

    private static let chatGPTMobileFallbackDocumentStartScript = #"""
    (() => {
      const enabledKey = 'contextport_chatgpt_mweb_fallback_enabled';
      const ownedURLKey = 'contextport_chatgpt_mweb_fallback_owned_url';

      let enabled = false;
      try {
        enabled = localStorage.getItem(enabledKey) === 'true';
      } catch (_) {}
      if (!enabled) return;

      let url;
      try {
        url = new URL(location.href);
      } catch (_) {
        return;
      }

      const host = url.hostname.toLowerCase();
      if (host !== 'chatgpt.com' && !host.endsWith('.chatgpt.com')) return;

      const components = url.pathname.split('/').filter(Boolean);
      const conversationIndex = components.indexOf('c');
      if (conversationIndex < 0 || conversationIndex >= components.length - 1) return;
      if (url.searchParams.has('mweb_fallback')) return;

      const ownedURL = new URL(url.toString());
      ownedURL.searchParams.delete('mweb_fallback');
      try {
        sessionStorage.setItem(ownedURLKey, ownedURL.toString());
      } catch (_) {}

      url.searchParams.set('mweb_fallback', '1');
      location.replace(url.toString());
    })();
    """#

    private static let chatGPTMobileFallbackReadyScript = #"""
    (() => {
      try {
        window.webkit?.messageHandlers?.contextPortChatGPTMobileFallbackReady?.postMessage('ready');
      } catch (_) {}
    })();
    """#
}
