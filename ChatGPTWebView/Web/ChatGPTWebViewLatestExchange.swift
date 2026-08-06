import Foundation
import WebKit

private struct LatestExchangeDOMConfiguration {
    let messageSelectors: [String]
}

private final class LatestExchangeConfigurationBox: NSObject {
    var configuration: ChatPerformanceConfiguration = .disabled
    var isScriptInstalled = false
    var bridge: LatestExchangeScriptBridge?
}

private final class LatestExchangeScriptBridge: NSObject, WKScriptMessageHandler {
    weak var store: ChatGPTWebViewStore?

    init(store: ChatGPTWebViewStore) {
        self.store = store
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == ChatGPTWebViewStore.latestExchangeReadyMessageName else {
            return
        }

        let store = self.store
        Task { @MainActor in
            store?.applyLatestExchangeConfigurationToPage()
        }
    }
}

@MainActor
private final class LatestExchangeRegistry {
    static let shared = LatestExchangeRegistry()

    private let boxes = NSMapTable<ChatGPTWebViewStore, LatestExchangeConfigurationBox>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    func box(for store: ChatGPTWebViewStore) -> LatestExchangeConfigurationBox {
        if let existing = boxes.object(forKey: store) {
            return existing
        }

        let box = LatestExchangeConfigurationBox()
        boxes.setObject(box, forKey: store)
        return box
    }
}

@MainActor
extension ChatGPTWebViewStore {
    static let latestExchangeReadyMessageName = "contextPortLatestExchangeReady"

    func updateLatestExchangeConfiguration(_ configuration: ChatPerformanceConfiguration) {
        let box = LatestExchangeRegistry.shared.box(for: self)
        box.configuration = configuration

        let installedNow = installLatestExchangeScriptIfNeeded(box: box)
        guard webView.url != nil else {
            return
        }

        if installedNow {
            webView.evaluateJavaScript(Self.latestExchangeBootstrapScript(for: provider.id)) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.applyLatestExchangeConfigurationToPage()
                }
            }
        } else {
            applyLatestExchangeConfigurationToPage()
        }
    }

    func applyLatestExchangeConfigurationToPage() {
        let box = LatestExchangeRegistry.shared.box(for: self)
        let configuration = box.configuration
        let pageEnabled = configuration.isLatestExchangeOnlyEnabled(for: provider.id)
            && provider.isAuthenticatedContentURL(webView.url)

        let payload: [String: Any] = [
            "enabled": pageEnabled
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let script = #"""
        (() => {
          const manager = window.__contextPortLatestExchange;
          if (!manager || typeof manager.configure !== 'function') {
            return { installed: false };
          }
          return manager.configure(\#(json));
        })();
        """#

        webView.evaluateJavaScript(script) { _, _ in }
    }

    private func installLatestExchangeScriptIfNeeded(box: LatestExchangeConfigurationBox) -> Bool {
        guard !box.isScriptInstalled else {
            return false
        }

        let bridge = LatestExchangeScriptBridge(store: self)
        let controller = webView.configuration.userContentController
        controller.add(bridge, name: Self.latestExchangeReadyMessageName)
        controller.addUserScript(
            WKUserScript(
                source: Self.latestExchangeBootstrapScript(for: provider.id),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        box.bridge = bridge
        box.isScriptInstalled = true
        return true
    }

    private static func latestExchangeBootstrapScript(for providerID: AIProviderID) -> String {
        let domConfiguration = latestExchangeDOMConfiguration(for: providerID)
        let providerLiteral = latestExchangeJavascriptArray([providerID.rawValue])
        let messageSelectors = latestExchangeJavascriptArray(domConfiguration.messageSelectors)
        let readyMessageName = latestExchangeJavascriptArray([latestExchangeReadyMessageName])

        return #"""
        (() => {
          const KEY = '__contextPortLatestExchange';
          const PROVIDER_ID = \#(providerLiteral)[0];
          const MESSAGE_SELECTORS = \#(messageSelectors);
          const READY_MESSAGE = \#(readyMessageName)[0];
          const HIDDEN_CLASS = 'contextport-latest-exchange-hidden';
          const TRACKED_ATTRIBUTE = 'data-contextport-latest-exchange-message';
          const STYLE_ID = 'contextport-latest-exchange-style';
          const VISIBLE_EXCHANGE_MESSAGES = 2;

          const notifyNative = () => {
            try {
              window.webkit?.messageHandlers?.[READY_MESSAGE]?.postMessage(PROVIDER_ID);
            } catch {}
          };

          const existing = window[KEY];
          if (existing?.providerID === PROVIDER_ID && typeof existing.configure === 'function') {
            notifyNative();
            return;
          }
          if (existing && typeof existing.destroy === 'function') {
            existing.destroy();
          }

          const state = {
            enabled: false,
            messages: [],
            hiddenCount: 0,
            observer: null,
            mutationTimer: null,
            animationFrame: null,
            lastURL: location.href
          };

          const ensureStyle = () => {
            if (document.getElementById(STYLE_ID)) return;
            const style = document.createElement('style');
            style.id = STYLE_ID;
            style.textContent = `.${HIDDEN_CLASS}{display:none!important}`;
            (document.head || document.documentElement).appendChild(style);
          };

          const removeStyle = () => {
            document.getElementById(STYLE_ID)?.remove();
          };

          const queryMessages = () => {
            for (const selector of MESSAGE_SELECTORS) {
              try {
                const found = Array.from(document.querySelectorAll(selector))
                  .filter(element => element instanceof HTMLElement);
                if (found.length === 0) continue;

                return found.filter(element => {
                  const parent = element.parentElement;
                  if (!parent) return true;
                  try {
                    return !parent.closest(selector);
                  } catch {
                    return true;
                  }
                });
              } catch {}
            }
            return [];
          };

          const nodeTouchesMessages = node => {
            if (!(node instanceof Element)) return false;
            for (const selector of MESSAGE_SELECTORS) {
              try {
                if (node.matches(selector) || node.querySelector(selector)) return true;
              } catch {}
            }
            return false;
          };

          const setHidden = (element, hidden) => {
            if (hidden) {
              if (!element.classList.contains(HIDDEN_CLASS)) {
                element.classList.add(HIDDEN_CLASS);
                element.setAttribute('aria-hidden', 'true');
              }
            } else if (element.classList.contains(HIDDEN_CLASS)) {
              element.classList.remove(HIDDEN_CLASS);
              element.removeAttribute('aria-hidden');
            }
          };

          const restoreTrackedMessages = () => {
            for (const element of state.messages) {
              setHidden(element, false);
              element.removeAttribute(TRACKED_ATTRIBUTE);
            }
            state.hiddenCount = 0;
          };

          const applyVisibility = () => {
            if (!state.enabled) {
              restoreTrackedMessages();
              return;
            }

            ensureStyle();
            const cutoff = Math.max(0, state.messages.length - VISIBLE_EXCHANGE_MESSAGES);
            state.hiddenCount = cutoff;

            for (let index = 0; index < state.messages.length; index += 1) {
              const element = state.messages[index];
              if (!element.hasAttribute(TRACKED_ATTRIBUTE)) {
                element.setAttribute(TRACKED_ATTRIBUTE, 'true');
              }
              setHidden(element, index < cutoff);
            }
          };

          const syncMessages = () => {
            state.lastURL = location.href;
            const previousMessages = state.messages;
            const nextMessages = queryMessages();
            const nextSet = new Set(nextMessages);

            for (const element of previousMessages) {
              if (!nextSet.has(element)) {
                setHidden(element, false);
                element.removeAttribute(TRACKED_ATTRIBUTE);
              }
            }

            state.messages = nextMessages;
            applyVisibility();
          };

          const scheduleSync = () => {
            if (state.animationFrame !== null) return;
            state.animationFrame = requestAnimationFrame(() => {
              state.animationFrame = null;
              syncMessages();
            });
          };

          const handleMutations = mutations => {
            let relevant = location.href !== state.lastURL;

            if (!relevant) {
              outer: for (const mutation of mutations) {
                for (const node of mutation.addedNodes) {
                  if (nodeTouchesMessages(node)) {
                    relevant = true;
                    break outer;
                  }
                }
                for (const node of mutation.removedNodes) {
                  if (nodeTouchesMessages(node)) {
                    relevant = true;
                    break outer;
                  }
                }
              }
            }

            if (!relevant) return;
            if (state.mutationTimer !== null) clearTimeout(state.mutationTimer);
            state.mutationTimer = setTimeout(() => {
              state.mutationTimer = null;
              scheduleSync();
            }, 80);
          };

          const startObserver = () => {
            if (state.observer) return;
            state.observer = new MutationObserver(handleMutations);
            state.observer.observe(document.documentElement, {
              childList: true,
              subtree: true
            });
          };

          const stopObserver = () => {
            state.observer?.disconnect();
            state.observer = null;
            if (state.mutationTimer !== null) {
              clearTimeout(state.mutationTimer);
              state.mutationTimer = null;
            }
            if (state.animationFrame !== null) {
              cancelAnimationFrame(state.animationFrame);
              state.animationFrame = null;
            }
          };

          const status = () => ({
            installed: true,
            providerID: PROVIDER_ID,
            enabled: state.enabled,
            totalMessages: state.messages.length,
            visibleMessages: Math.max(0, state.messages.length - state.hiddenCount),
            hiddenMessages: state.hiddenCount
          });

          const manager = {
            providerID: PROVIDER_ID,
            configure(nextConfiguration) {
              const nextEnabled = Boolean(nextConfiguration?.enabled);
              state.enabled = nextEnabled;

              if (!state.enabled) {
                stopObserver();
                restoreTrackedMessages();
                removeStyle();
                return status();
              }

              ensureStyle();
              startObserver();
              syncMessages();
              return status();
            },
            destroy() {
              stopObserver();
              restoreTrackedMessages();
              removeStyle();
              if (window[KEY] === manager) delete window[KEY];
            },
            status
          };

          window[KEY] = manager;
          notifyNative();
        })();
        """#
    }

    private static func latestExchangeDOMConfiguration(
        for providerID: AIProviderID
    ) -> LatestExchangeDOMConfiguration {
        switch providerID {
        case .chatGPT:
            return LatestExchangeDOMConfiguration(
                messageSelectors: [
                    "section[data-testid^=\"conversation-turn-\"]",
                    "[data-message-author-role]"
                ]
            )
        case .claude:
            return LatestExchangeDOMConfiguration(
                messageSelectors: [
                    "[data-test-render-count]"
                ]
            )
        case .gemini:
            return LatestExchangeDOMConfiguration(
                messageSelectors: [
                    "user-query, model-response"
                ]
            )
        case .grok:
            return LatestExchangeDOMConfiguration(
                messageSelectors: [
                    "main article",
                    "main [data-message-id]",
                    "main [data-testid*=\"message\"]"
                ]
            )
        case .deepSeek:
            return LatestExchangeDOMConfiguration(
                messageSelectors: []
            )
        }
    }

    private static func latestExchangeJavascriptArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
