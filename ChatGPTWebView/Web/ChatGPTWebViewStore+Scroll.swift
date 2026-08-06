import Foundation
import WebKit

@MainActor
extension ChatGPTWebViewStore {
    func scrollCurrentConversationToBottom() {
        let script = #"""
        (() => {
          try {
            if (typeof window.__contextPortScrollToBottom === 'function') {
              const followed = window.__contextPortScrollToBottom();
              if (followed) return true;
            }
          } catch (_) {}

          const viewportArea = Math.max(1, window.innerWidth * window.innerHeight);
          const candidates = [
            document.scrollingElement,
            document.documentElement,
            document.body,
            ...Array.from(document.querySelectorAll(
              'main, [role="main"], [data-scroll-root], [class*="overflow-y-auto"], [class*="overflow-y-scroll"], [style*="overflow-y"]'
            ))
          ].filter(Boolean);

          var best = null;
          var bestScore = 0;

          for (const element of Array.from(new Set(candidates))) {
            if (!(element instanceof Element)) continue;

            const overflow = Math.max(0, element.scrollHeight - element.clientHeight);
            if (overflow < 40) continue;

            let style;
            try {
              style = window.getComputedStyle(element);
            } catch (_) {
              continue;
            }

            const overflowY = String(style.overflowY || '').toLowerCase();
            const permitsScroll = overflowY === 'auto'
              || overflowY === 'scroll'
              || element === document.scrollingElement
              || element === document.documentElement
              || element === document.body;
            if (!permitsScroll) continue;

            const rect = element.getBoundingClientRect();
            const visibleWidth = Math.max(0, Math.min(window.innerWidth, rect.right) - Math.max(0, rect.left));
            const visibleHeight = Math.max(0, Math.min(window.innerHeight, rect.bottom) - Math.max(0, rect.top));
            const visibleArea = visibleWidth * visibleHeight;
            const score = overflow + Math.min(viewportArea, visibleArea);

            if (score > bestScore) {
              best = element;
              bestScore = score;
            }
          }

          const target = best || document.scrollingElement || document.documentElement || document.body;
          if (!target) return false;

          try {
            target.scrollTo({ top: target.scrollHeight, left: 0, behavior: 'smooth' });
          } catch (_) {
            target.scrollLeft = 0;
            target.scrollTop = target.scrollHeight;
          }

          try {
            window.scrollTo({ top: document.documentElement.scrollHeight, left: 0, behavior: 'smooth' });
          } catch (_) {}

          return true;
        })();
        """#

        webView.evaluateJavaScript(script) { [weak webView] value, _ in
            guard value as? Bool != true, let scrollView = webView?.scrollView else { return }
            let bottomOffset = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
            )
            scrollView.setContentOffset(
                CGPoint(x: 0, y: bottomOffset),
                animated: true
            )
        }
    }
}
