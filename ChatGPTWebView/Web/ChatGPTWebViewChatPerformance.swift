import Foundation
import WebKit

// Conversation-windowing design is inspired by Noah Thiering's
// AI Chat Speed Booster (MIT License). ContextPort reimplements the idea for
// native WKWebView sessions and intentionally does not intercept AI API responses.

private struct ChatPerformanceDOMConfiguration {
    let messageSelectors: [String]
    let scrollSelectors: [String]
}

private final class ChatPerformanceConfigurationBox: NSObject {
    var configuration: ChatPerformanceConfiguration = .disabled
    var isScriptInstalled = false
    var bridge: ChatPerformanceScriptBridge?
}

private final class ChatPerformanceScriptBridge: NSObject, WKScriptMessageHandler {
    weak var store: ChatGPTWebViewStore?

    init(store: ChatGPTWebViewStore) {
        self.store = store
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == ChatGPTWebViewStore.chatPerformanceReadyMessageName else {
            return
        }

        let store = self.store
        Task { @MainActor in
            store?.applyChatPerformanceConfigurationToPage()
        }
    }
}

@MainActor
private final class ChatPerformanceRegistry {
    static let shared = ChatPerformanceRegistry()

    private let boxes = NSMapTable<ChatGPTWebViewStore, ChatPerformanceConfigurationBox>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    func box(for store: ChatGPTWebViewStore) -> ChatPerformanceConfigurationBox {
        if let existing = boxes.object(forKey: store) {
            return existing
        }

        let box = ChatPerformanceConfigurationBox()
        boxes.setObject(box, forKey: store)
        return box
    }
}

@MainActor
extension ChatGPTWebViewStore {
    static let chatPerformanceReadyMessageName = "contextPortChatPerformanceReady"

    func updateChatPerformanceConfiguration(_ configuration: ChatPerformanceConfiguration) {
        let box = ChatPerformanceRegistry.shared.box(for: self)
        box.configuration = configuration

        let installedNow = installChatPerformanceScriptIfNeeded(box: box)
        guard webView.url != nil else {
            return
        }

        if installedNow {
            webView.evaluateJavaScript(Self.chatPerformanceBootstrapScript(for: provider.id)) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.applyChatPerformanceConfigurationToPage()
                }
            }
        } else {
            applyChatPerformanceConfigurationToPage()
        }
    }

    func applyChatPerformanceConfigurationToPage() {
        let box = ChatPerformanceRegistry.shared.box(for: self)
        let configuration = box.configuration
        let pageEnabled = configuration.isEnabled(for: provider.id)
            && provider.isAuthenticatedContentURL(webView.url)

        let payload: [String: Any] = [
            "enabled": pageEnabled,
            "visibleMessageLimit": configuration.visibleMessageLimit,
            "revealBatchSize": 10
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let script = #"""
        (() => {
          const manager = window.__contextPortChatPerformance;
          if (!manager || typeof manager.configure !== 'function') {
            return { installed: false };
          }
          return manager.configure(\#(json));
        })();
        """#

        webView.evaluateJavaScript(script) { _, _ in }
    }

    private func installChatPerformanceScriptIfNeeded(box: ChatPerformanceConfigurationBox) -> Bool {
        guard !box.isScriptInstalled else {
            return false
        }

        let bridge = ChatPerformanceScriptBridge(store: self)
        let controller = webView.configuration.userContentController
        controller.add(bridge, name: Self.chatPerformanceReadyMessageName)
        controller.addUserScript(
            WKUserScript(
                source: Self.chatPerformanceBootstrapScript(for: provider.id),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        box.bridge = bridge
        box.isScriptInstalled = true
        return true
    }

    private static func chatPerformanceBootstrapScript(for providerID: AIProviderID) -> String {
        let domConfiguration = chatPerformanceDOMConfiguration(for: providerID)
        let providerLiteral = javascriptArray([providerID.rawValue])
        let messageSelectors = javascriptArray(domConfiguration.messageSelectors)
        let scrollSelectors = javascriptArray(domConfiguration.scrollSelectors)
        let readyMessageName = javascriptArray([chatPerformanceReadyMessageName])

        return #"""
        (() => {
          const KEY = '__contextPortChatPerformance';
          const PROVIDER_ID = \#(providerLiteral)[0];
          const MESSAGE_SELECTORS = \#(messageSelectors);
          const SCROLL_SELECTORS = \#(scrollSelectors);
          const READY_MESSAGE = \#(readyMessageName)[0];
          const HIDDEN_CLASS = 'contextport-performance-hidden';
          const TRACKED_ATTRIBUTE = 'data-contextport-performance-message';
          const STYLE_ID = 'contextport-chat-performance-style';

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
            visibleMessageLimit: 20,
            revealBatchSize: 10,
            expandedVisibleLimit: 20,
            messages: [],
            hiddenCount: 0,
            observer: null,
            mutationTimer: null,
            animationFrame: null,
            scrollElement: null,
            lastURL: location.href,
            lastRevealAt: 0
          };

          const clamp = (value, minimum, maximum) => Math.min(Math.max(value, minimum), maximum);

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
            const activeLimit = Math.max(
              state.visibleMessageLimit,
              state.expandedVisibleLimit
            );
            const cutoff = Math.max(0, state.messages.length - activeLimit);
            state.hiddenCount = cutoff;

            for (let index = 0; index < state.messages.length; index += 1) {
              const element = state.messages[index];
              if (!element.hasAttribute(TRACKED_ATTRIBUTE)) {
                element.setAttribute(TRACKED_ATTRIBUTE, 'true');
              }
              setHidden(element, index < cutoff);
            }
          };

          const findScrollElement = () => {
            for (const selector of SCROLL_SELECTORS) {
              try {
                const element = document.querySelector(selector);
                if (element instanceof HTMLElement) return element;
              } catch {}
            }
            return null;
          };

          const revealOlderMessages = () => {
            if (!state.enabled || state.hiddenCount <= 0) return;
            const nextLimit = Math.max(
              state.expandedVisibleLimit,
              state.visibleMessageLimit
            ) + state.revealBatchSize;
            state.expandedVisibleLimit = Math.min(state.messages.length, nextLimit);
            applyVisibility();
          };

          const handleScroll = () => {
            if (!state.enabled || state.hiddenCount <= 0 || !state.scrollElement) return;

            const now = Date.now();
            if (now - state.lastRevealAt < 350) return;

            const maximum = state.scrollElement.scrollHeight - state.scrollElement.clientHeight;
            const percentFromTop = maximum > 0
              ? (state.scrollElement.scrollTop / maximum) * 100
              : 100;
            if (percentFromTop > 10) return;

            state.lastRevealAt = now;
            revealOlderMessages();
          };

          const attachScrollListener = () => {
            const nextScrollElement = findScrollElement();
            if (nextScrollElement === state.scrollElement) return;

            state.scrollElement?.removeEventListener('scroll', handleScroll);
            state.scrollElement = nextScrollElement;
            state.scrollElement?.addEventListener('scroll', handleScroll, { passive: true });
          };

          const syncMessages = () => {
            const currentURL = location.href;
            if (currentURL !== state.lastURL) {
              state.lastURL = currentURL;
              state.expandedVisibleLimit = state.visibleMessageLimit;
            }

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
            attachScrollListener();
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
              const nextLimit = clamp(
                Number(nextConfiguration?.visibleMessageLimit) || 20,
                5,
                100
              );
              const nextBatchSize = clamp(
                Number(nextConfiguration?.revealBatchSize) || 10,
                5,
                25
              );
              const nextEnabled = Boolean(nextConfiguration?.enabled);
              const limitChanged = nextLimit !== state.visibleMessageLimit;
              const enabling = nextEnabled && !state.enabled;

              state.visibleMessageLimit = nextLimit;
              state.revealBatchSize = nextBatchSize;
              state.enabled = nextEnabled;

              if (limitChanged || enabling) {
                state.expandedVisibleLimit = nextLimit;
              }

              if (!state.enabled) {
                stopObserver();
                state.scrollElement?.removeEventListener('scroll', handleScroll);
                state.scrollElement = null;
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
              state.scrollElement?.removeEventListener('scroll', handleScroll);
              state.scrollElement = null;
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

    private static func chatPerformanceDOMConfiguration(
        for providerID: AIProviderID
    ) -> ChatPerformanceDOMConfiguration {
        switch providerID {
        case .chatGPT:
            return ChatPerformanceDOMConfiguration(
                messageSelectors: [
                    "section[data-testid^=\"conversation-turn-\"]",
                    "[data-message-author-role]"
                ],
                scrollSelectors: [
                    "div[data-scroll-root]",
                    "main"
                ]
            )
        case .claude:
            return ChatPerformanceDOMConfiguration(
                messageSelectors: [
                    "[data-test-render-count]"
                ],
                scrollSelectors: [
                    "div[data-autoscroll-container]",
                    ".overflow-y-scroll"
                ]
            )
        case .gemini:
            return ChatPerformanceDOMConfiguration(
                messageSelectors: [
                    "user-query, model-response"
                ],
                scrollSelectors: [
                    "infinite-scroller[data-test-id=\"chat-history-container\"]",
                    "infinite-scroller.chat-history"
                ]
            )
        case .grok:
            return ChatPerformanceDOMConfiguration(
                messageSelectors: [
                    "main article",
                    "main [data-message-id]",
                    "main [data-testid*=\"message\"]"
                ],
                scrollSelectors: [
                    "main"
                ]
            )
        case .deepSeek:
            return ChatPerformanceDOMConfiguration(
                messageSelectors: [],
                scrollSelectors: []
            )
        }
    }

    private static func javascriptArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
