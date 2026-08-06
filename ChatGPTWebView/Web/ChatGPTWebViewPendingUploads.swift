import UIKit
import UniformTypeIdentifiers
import WebKit

struct ChatAttachmentHandoffResult: Sendable {
    let attachedURLs: [URL]
    let unsupportedURLs: [URL]
    let failedURLs: [URL]

    var completedWithoutRetry: Bool {
        failedURLs.isEmpty
    }
}

private final class WebViewOpenPanelDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]?) -> Void

    init(completion: @escaping ([URL]?) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }
}

private enum PendingUploadRegistry {
    static var pendingURLsByCoordinator: [ObjectIdentifier: [URL]] = [:]
    static var delegatesByCoordinator: [ObjectIdentifier: WebViewOpenPanelDelegate] = [:]
}

extension SecureChatGPTWebViewCoordinator {
    func setPendingUploadURLs(_ urls: [URL]) {
        let key = ObjectIdentifier(self)
        PendingUploadRegistry.pendingURLsByCoordinator[key] = urls
    }

    func hasPendingUploadURLs() -> Bool {
        let key = ObjectIdentifier(self)
        return !(PendingUploadRegistry.pendingURLsByCoordinator[key] ?? []).isEmpty
    }

    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let key = ObjectIdentifier(self)
        let pendingURLs = PendingUploadRegistry.pendingURLsByCoordinator[key] ?? []

        if !pendingURLs.isEmpty {
            PendingUploadRegistry.pendingURLsByCoordinator[key] = []
            let urls = parameters.allowsMultipleSelection ? pendingURLs : Array(pendingURLs.prefix(1))
            completionHandler(urls)
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection

        let delegate = WebViewOpenPanelDelegate { urls in
            PendingUploadRegistry.delegatesByCoordinator[key] = nil
            completionHandler(urls)
        }

        PendingUploadRegistry.delegatesByCoordinator[key] = delegate
        picker.delegate = delegate

        guard let presenter = Self.topViewController() else {
            PendingUploadRegistry.delegatesByCoordinator[key] = nil
            completionHandler(nil)
            return
        }

        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController

        return topViewController(from: root)
    }

    private static func topViewController(from controller: UIViewController?) -> UIViewController? {
        if let navigation = controller as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }

        if let tab = controller as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }

        if let presented = controller?.presentedViewController {
            return topViewController(from: presented)
        }

        return controller
    }
}

@MainActor
extension ChatGPTWebViewStore {
    func preparePendingUploadURLs(_ urls: [URL]) {
        coordinator.setPendingUploadURLs(urls)
    }

    func startNewChatWithPendingUploadURLs(_ urls: [URL]) {
        coordinator.setPendingUploadURLs(urls)
        startNewChat()
    }

    func triggerPendingAttachmentPicker() async {
        guard coordinator.hasPendingUploadURLs() else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard coordinator.hasPendingUploadURLs() else { return }
        _ = await activateComposerAndOpenAttachmentPicker()
    }

    func activateComposerAndOpenAttachmentPicker() async -> Bool {
        let script = #"""
        (() => {
          const visible = (el) => {
            if (!el) return false;
            const r = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return r.width > 12 && r.height > 12 && style.visibility !== 'hidden' && style.display !== 'none';
          };

          const tapLikeUser = (el) => {
            if (!el) return false;
            const r = el.getBoundingClientRect();
            const x = Math.max(1, Math.floor(r.left + Math.min(Math.max(r.width - 1, 1), Math.max(18, r.width / 2))));
            const y = Math.max(1, Math.floor(r.top + Math.min(Math.max(r.height - 1, 1), Math.max(12, r.height / 2))));
            const mouse = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y };
            const pointer = { bubbles: true, cancelable: true, pointerId: 1, pointerType: 'touch', isPrimary: true, clientX: x, clientY: y };
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
            try { el.dispatchEvent(new PointerEvent('pointerover', pointer)); } catch (_) {}
            try { el.dispatchEvent(new PointerEvent('pointerdown', pointer)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mouseover', mouse));
            el.dispatchEvent(new MouseEvent('mousedown', mouse));
            el.dispatchEvent(new MouseEvent('mouseup', mouse));
            try { el.dispatchEvent(new PointerEvent('pointerup', pointer)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('click', mouse));
            el.focus?.({ preventScroll: true });
            return true;
          };

          const composerSelectors = [
            'textarea',
            '[contenteditable="true"]',
            '.ProseMirror',
            '[data-testid="composer"] [contenteditable="true"]',
            '[data-testid="composer"] textarea',
            'form textarea',
            'form [contenteditable="true"]'
          ];

          const findComposer = () => {
            for (const selector of composerSelectors) {
              const candidates = Array.from(document.querySelectorAll(selector)).filter(visible);
              if (candidates.length) return candidates[candidates.length - 1];
            }
            return null;
          };

          const composer = findComposer();
          const composerRect = composer?.getBoundingClientRect?.() || null;
          if (composer) {
            tapLikeUser(composer);
          } else {
            const shell = Array.from(document.querySelectorAll('form, [data-testid="composer"], main')).reverse().find(visible);
            if (shell) tapLikeUser(shell);
          }

          const labelFor = (candidate) => [
            candidate.innerText,
            candidate.textContent,
            candidate.getAttribute('aria-label'),
            candidate.getAttribute('title'),
            candidate.getAttribute('data-testid')
          ].filter(Boolean).join(' ').trim().toLowerCase();

          const attachScore = (candidate) => {
            const label = labelFor(candidate);
            let score = 0;
            if (label.includes('attach')) score += 100;
            if (label.includes('upload')) score += 100;
            if (label.includes('file')) score += 80;
            if (label.includes('add')) score += 40;
            if (label === '+' || label.includes('plus')) score += 40;
            if (!score) return -1;
            const r = candidate.getBoundingClientRect();
            if (composerRect) {
              score -= Math.min(80, Math.abs(r.top - composerRect.top) / 4);
              score -= Math.min(40, Math.abs(r.left - composerRect.left) / 8);
            }
            if (r.top > window.innerHeight * 0.55) score += 20;
            return score;
          };

          const buttons = Array.from(document.querySelectorAll('button,[role="button"],a,input[type="button"]')).filter(visible);
          const attachButton = buttons
            .map((candidate) => ({ candidate, score: attachScore(candidate) }))
            .filter((item) => item.score >= 0)
            .sort((a, b) => b.score - a.score)[0]?.candidate;

          if (attachButton) {
            tapLikeUser(attachButton);
            setTimeout(() => {
              const menuItem = Array.from(document.querySelectorAll('button,[role="button"],a,[role="menuitem"]'))
                .filter(visible)
                .find((candidate) => {
                  const label = labelFor(candidate);
                  return label.includes('upload') || label.includes('file') || label.includes('computer') || label.includes('photo');
                });
              if (menuItem) tapLikeUser(menuItem);
              setTimeout(() => document.querySelector('input[type="file"]')?.click(), 250);
            }, 250);
            return true;
          }

          const input = document.querySelector('input[type="file"]');
          if (input) {
            input.click();
            return true;
          }

          return false;
        })();
        """#

        let value = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }

        return (value as? Bool) == true
    }

    func injectFilesIntoChatGPTUpload(_ urls: [URL]) async -> ChatAttachmentHandoffResult {
        struct FileDescriptor {
            let id: String
            let name: String
            let mime: String
            let url: URL
        }

        struct AttachmentBridgeResult: Decodable {
            let attachedIDs: [String]
            let unsupportedIDs: [String]
            let failedIDs: [String]
        }

        let uploadChunkSize = 384 * 1024
        let fileManager = FileManager.default
        let existingURLs = urls.filter { fileManager.fileExists(atPath: $0.path) }
        let missingURLs = urls.filter { !fileManager.fileExists(atPath: $0.path) }

        func failedResult(_ failedURLs: [URL] = urls) -> ChatAttachmentHandoffResult {
            ChatAttachmentHandoffResult(
                attachedURLs: [],
                unsupportedURLs: [],
                failedURLs: failedURLs
            )
        }

        guard !existingURLs.isEmpty else {
            return failedResult()
        }

        func evaluateBool(_ script: String) async -> Bool {
            let value = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
            return (value as? Bool) == true
        }

        func evaluateString(_ script: String) async -> String? {
            let value = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
            return value as? String
        }

        func jsonObject(_ object: [String: String]) -> String? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: []),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return json
        }

        func cleanupUploadBridge() async {
            _ = await evaluateBool(
                "(() => { try { delete window.__contextPortUploadBridge; } catch (_) {} return true; })();"
            )
        }

        let initialized = await evaluateBool(#"""
        (() => {
          try { delete window.__contextPortUploadBridge; } catch (_) {}
          window.__contextPortUploadBridge = { files: [] };
          return true;
        })();
        """#)
        guard initialized else {
            return failedResult()
        }

        var descriptors: [FileDescriptor] = []
        for url in existingURLs {
            let descriptor = FileDescriptor(
                id: UUID().uuidString,
                name: url.lastPathComponent,
                mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                url: url
            )

            guard let descriptorJSON = jsonObject([
                "id": descriptor.id,
                "name": descriptor.name,
                "mime": descriptor.mime
            ]) else {
                await cleanupUploadBridge()
                return failedResult()
            }

            let registered = await evaluateBool("""
            (() => {
              const bridge = window.__contextPortUploadBridge;
              if (!bridge || !Array.isArray(bridge.files)) return false;
              const descriptor = \(descriptorJSON);
              bridge.files.push({ ...descriptor, parts: [] });
              return true;
            })();
            """)
            guard registered else {
                await cleanupUploadBridge()
                return failedResult()
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else {
                await cleanupUploadBridge()
                return failedResult()
            }

            var fileReadSucceeded = true
            do {
                while let chunk = try handle.read(upToCount: uploadChunkSize), !chunk.isEmpty {
                    let base64 = chunk.base64EncodedString()
                    let staged = await evaluateBool("""
                    (() => {
                      const bridge = window.__contextPortUploadBridge;
                      const file = bridge?.files?.find((candidate) => candidate.id === '\(descriptor.id)');
                      if (!file) return false;
                      const binary = atob('\(base64)');
                      const bytes = new Uint8Array(binary.length);
                      for (let index = 0; index < binary.length; index++) {
                        bytes[index] = binary.charCodeAt(index);
                      }
                      file.parts.push(bytes);
                      return true;
                    })();
                    """)
                    if !staged {
                        fileReadSucceeded = false
                        break
                    }
                }
            } catch {
                fileReadSucceeded = false
            }
            try? handle.close()

            guard fileReadSucceeded else {
                await cleanupUploadBridge()
                return failedResult()
            }
            descriptors.append(descriptor)
        }

        let attachScript = #"""
        (async () => {
          const bridge = window.__contextPortUploadBridge;
          const emptyResult = {
            attachedIDs: [],
            unsupportedIDs: [],
            failedIDs: []
          };
          if (!bridge || !Array.isArray(bridge.files) || bridge.files.length === 0) {
            return JSON.stringify(emptyResult);
          }

          const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

          const visible = (el) => {
            if (!el) return false;
            const r = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return r.width > 12 && r.height > 12 && style.visibility !== 'hidden' && style.display !== 'none';
          };

          const tapLikeUser = (el) => {
            if (!el) return false;
            const r = el.getBoundingClientRect();
            const x = Math.max(1, Math.floor(r.left + Math.min(Math.max(r.width - 1, 1), Math.max(18, r.width / 2))));
            const y = Math.max(1, Math.floor(r.top + Math.min(Math.max(r.height - 1, 1), Math.max(12, r.height / 2))));
            const mouse = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y };
            const pointer = { bubbles: true, cancelable: true, pointerId: 1, pointerType: 'touch', isPrimary: true, clientX: x, clientY: y };
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
            try { el.dispatchEvent(new PointerEvent('pointerover', pointer)); } catch (_) {}
            try { el.dispatchEvent(new PointerEvent('pointerdown', pointer)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mouseover', mouse));
            el.dispatchEvent(new MouseEvent('mousedown', mouse));
            el.dispatchEvent(new MouseEvent('mouseup', mouse));
            try { el.dispatchEvent(new PointerEvent('pointerup', pointer)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('click', mouse));
            el.focus?.({ preventScroll: true });
            return true;
          };

          const findComposer = () => {
            const selectors = [
              'textarea',
              '[contenteditable="true"]',
              '.ProseMirror',
              '[data-testid="composer"] [contenteditable="true"]',
              '[data-testid="composer"] textarea',
              'form textarea',
              'form [contenteditable="true"]'
            ];
            for (const selector of selectors) {
              const candidates = Array.from(document.querySelectorAll(selector)).filter(visible);
              if (candidates.length) return candidates[candidates.length - 1];
            }
            return null;
          };

          const closeTransientMenus = () => {
            const escDown = new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true, cancelable: true });
            const escUp = new KeyboardEvent('keyup', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true, cancelable: true });
            document.dispatchEvent(escDown);
            window.dispatchEvent(escDown);
            document.body?.dispatchEvent(escDown);
            document.dispatchEvent(escUp);
            window.dispatchEvent(escUp);
            document.body?.dispatchEvent(escUp);

            const composer = findComposer();
            if (composer) {
              tapLikeUser(composer);
            } else {
              document.body?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: 8, clientY: 8 }));
            }
          };

          const pairs = bridge.files.map((record) => ({
            record,
            file: new File(
              record.parts,
              record.name,
              { type: record.mime || 'application/octet-stream' }
            )
          }));

          const composer = findComposer();
          if (composer) tapLikeUser(composer);
          await wait(200);

          const input = Array.from(document.querySelectorAll('input[type="file"]')).reverse()[0];

          const acceptsFile = (candidateInput, file) => {
            const rawAccept = String(candidateInput?.getAttribute('accept') || '').trim().toLowerCase();
            if (!rawAccept) return true;

            const tokens = rawAccept
              .split(',')
              .map((token) => token.trim())
              .filter(Boolean);
            if (!tokens.length) return true;

            const lowerName = String(file.name || '').toLowerCase();
            const dotIndex = lowerName.lastIndexOf('.');
            const extension = dotIndex >= 0 ? lowerName.slice(dotIndex) : '';
            const mime = String(file.type || '').toLowerCase();

            return tokens.some((token) => {
              if (token.startsWith('.')) return token === extension;
              if (token.endsWith('/*')) return mime.startsWith(token.slice(0, -1));
              return mime === token;
            });
          };

          const supportedPairs = input
            ? pairs.filter(({ file }) => acceptsFile(input, file))
            : pairs;
          const unsupportedIDs = input
            ? pairs.filter(({ file }) => !acceptsFile(input, file)).map(({ record }) => record.id)
            : [];

          if (!supportedPairs.length) {
            return JSON.stringify({
              attachedIDs: [],
              unsupportedIDs,
              failedIDs: []
            });
          }

          let transfer = null;
          try { transfer = new DataTransfer(); } catch (_) {}
          if (!transfer) {
            try { transfer = new ClipboardEvent('paste').clipboardData; } catch (_) {}
          }
          if (!transfer) {
            return JSON.stringify({
              attachedIDs: [],
              unsupportedIDs,
              failedIDs: supportedPairs.map(({ record }) => record.id)
            });
          }

          for (const { file } of supportedPairs) transfer.items.add(file);
          if (!transfer.files || transfer.files.length === 0) {
            return JSON.stringify({
              attachedIDs: [],
              unsupportedIDs,
              failedIDs: supportedPairs.map(({ record }) => record.id)
            });
          }

          const attachmentVisible = () => {
            const attachmentHints = Array.from(document.querySelectorAll('[data-testid], [aria-label], [data-filename], [title], [alt], a, button, div, span'))
              .map((el) => [
                el.innerText,
                el.textContent,
                el.getAttribute('aria-label'),
                el.getAttribute('data-testid'),
                el.getAttribute('data-filename'),
                el.getAttribute('title'),
                el.getAttribute('alt'),
                el.getAttribute('name'),
                el.getAttribute('value')
              ].filter(Boolean).join(' '))
              .join(' ')
              .toLowerCase();
            const attachmentHTML = String(document.documentElement?.innerHTML || '').toLowerCase();
            return supportedPairs.every(({ record }) => {
              const name = record.name.toLowerCase();
              return attachmentHints.includes(name) || attachmentHTML.includes(name);
            });
          };

          const fileListMatches = (fileList) => {
            const expectedFiles = supportedPairs.map(({ file }) => file);
            const actualFiles = Array.from(fileList || []);
            if (actualFiles.length !== expectedFiles.length) return false;
            return expectedFiles.every((file, index) => {
              const actual = actualFiles[index];
              return actual
                && actual.name === file.name
                && actual.size === file.size
                && String(actual.type || '') === String(file.type || '');
            });
          };

          if (input) {
            try {
              input.files = transfer.files;
              const browserAcceptedExactFiles = fileListMatches(input.files)
                && (supportedPairs.length === 1 || input.multiple);
              input.dispatchEvent(new Event('input', { bubbles: true }));
              input.dispatchEvent(new Event('change', { bubbles: true }));

              if (browserAcceptedExactFiles) {
                closeTransientMenus();
                await wait(250);
                return JSON.stringify({
                  attachedIDs: supportedPairs.map(({ record }) => record.id),
                  unsupportedIDs,
                  failedIDs: []
                });
              }

              for (let attempt = 0; attempt < 24; attempt++) {
                await wait(250);
                if (attachmentVisible()) {
                  closeTransientMenus();
                  await wait(250);
                  return JSON.stringify({
                    attachedIDs: supportedPairs.map(({ record }) => record.id),
                    unsupportedIDs,
                    failedIDs: []
                  });
                }
              }
            } catch (_) {}
          }

          const dropTargets = [
            composer,
            document.querySelector('form'),
            document.querySelector('[data-testid="composer"]'),
            document.querySelector('main'),
            document.body
          ].filter(Boolean);

          for (const target of dropTargets) {
            try {
              target.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer }));
            } catch (_) {}
            try {
              target.dispatchEvent(new DragEvent('dragenter', { bubbles: true, cancelable: true, dataTransfer: transfer }));
              target.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: transfer }));
              target.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: transfer }));
            } catch (_) {}

            for (let attempt = 0; attempt < 24; attempt++) {
              await wait(250);
              if (attachmentVisible()) {
                closeTransientMenus();
                await wait(250);
                return JSON.stringify({
                  attachedIDs: supportedPairs.map(({ record }) => record.id),
                  unsupportedIDs,
                  failedIDs: []
                });
              }
            }
          }

          return JSON.stringify({
            attachedIDs: [],
            unsupportedIDs,
            failedIDs: supportedPairs.map(({ record }) => record.id)
          });
        })();
        """#

        let rawResult = await evaluateString(attachScript)
        await cleanupUploadBridge()

        guard let rawResult,
              let resultData = rawResult.data(using: .utf8),
              let bridgeResult = try? JSONDecoder().decode(AttachmentBridgeResult.self, from: resultData) else {
            return failedResult()
        }

        let descriptorURLs = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.id, $0.url) }
        )
        let attachedURLs = bridgeResult.attachedIDs.compactMap { descriptorURLs[$0] }
        let unsupportedURLs = bridgeResult.unsupportedIDs.compactMap { descriptorURLs[$0] }
        var failedURLs = missingURLs + bridgeResult.failedIDs.compactMap { descriptorURLs[$0] }

        let accountedIDs = Set(
            bridgeResult.attachedIDs
            + bridgeResult.unsupportedIDs
            + bridgeResult.failedIDs
        )
        failedURLs.append(contentsOf: descriptors.compactMap {
            accountedIDs.contains($0.id) ? nil : $0.url
        })

        func orderedUnique(_ candidates: [URL]) -> [URL] {
            let candidatePaths = Set(candidates.map { $0.standardizedFileURL.path })
            var seen = Set<String>()
            return urls.filter {
                let path = $0.standardizedFileURL.path
                return candidatePaths.contains(path) && seen.insert(path).inserted
            }
        }

        return ChatAttachmentHandoffResult(
            attachedURLs: orderedUnique(attachedURLs),
            unsupportedURLs: orderedUnique(unsupportedURLs),
            failedURLs: orderedUnique(failedURLs)
        )
    }


    private func waitForStableComposerReady() async -> Bool {
        let readinessScript = #"""
        (() => {
          const selectors = [
            'textarea',
            '[contenteditable="true"]',
            '.ProseMirror',
            '[data-testid="composer"] [contenteditable="true"]',
            '[data-testid="composer"] textarea',
            'form textarea',
            'form [contenteditable="true"]'
          ];

          const visible = (el) => {
            if (!el) return false;
            const r = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return r.width > 80 && r.height > 12 && style.visibility !== 'hidden' && style.display !== 'none';
          };

          for (const selector of selectors) {
            const candidates = Array.from(document.querySelectorAll(selector)).filter(visible);
            if (candidates.length > 0) return true;
          }
          return false;
        })();
        """#

        var stableURL: URL?
        var stableChecks = 0

        for _ in 0..<150 {
            guard !Task.isCancelled else { return false }

            if !webView.isLoading,
               let currentURL = webView.url,
               provider.isAuthenticatedContentURL(currentURL) {
                let value = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                    webView.evaluateJavaScript(readinessScript) { value, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: value)
                        }
                    }
                }

                if (value as? Bool) == true,
                   !webView.isLoading,
                   webView.url == currentURL {
                    if stableURL == currentURL {
                        stableChecks += 1
                    } else {
                        stableURL = currentURL
                        stableChecks = 1
                    }

                    if stableChecks >= 2 {
                        return true
                    }
                } else {
                    stableURL = nil
                    stableChecks = 0
                }
            } else {
                stableURL = nil
                stableChecks = 0
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return false
    }

    func injectComposerText(_ text: String) async -> Bool {
        guard await waitForStableComposerReady() else {
            return false
        }

        let encodedText: String
        if let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
           let json = String(data: data, encoding: .utf8) {
            encodedText = json
        } else {
            encodedText = "[\"\"]"
        }

        let script = """
        (() => {
          const text = \(encodedText)[0];

          const selectors = [
            'textarea',
            '[contenteditable="true"]',
            '.ProseMirror',
            '[data-testid="composer"] [contenteditable="true"]',
            '[data-testid="composer"] textarea',
            'form textarea',
            'form [contenteditable="true"]'
          ];

          const visible = (el) => {
            if (!el) return false;
            const r = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return r.width > 80 && r.height > 12 && style.visibility !== 'hidden' && style.display !== 'none';
          };

          const findComposer = () => {
            for (const selector of selectors) {
              const candidates = Array.from(document.querySelectorAll(selector)).filter(visible);
              if (candidates.length) return candidates[candidates.length - 1];
            }
            return null;
          };

          const tapLikeUser = (el) => {
            const r = el.getBoundingClientRect();
            const x = Math.max(1, Math.floor(r.left + Math.min(r.width - 1, 24)));
            const y = Math.max(1, Math.floor(r.top + Math.min(r.height - 1, Math.max(12, r.height / 2))));
            const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y };
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
            el.dispatchEvent(new MouseEvent('mouseover', opts));
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            el.dispatchEvent(new MouseEvent('click', opts));
            el.focus?.({ preventScroll: true });
          };

          const setNativeValue = (el, value) => {
            const proto = Object.getPrototypeOf(el);
            const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
            if (descriptor && descriptor.set) {
              descriptor.set.call(el, value);
            } else {
              el.value = value;
            }
          };

          const insertInto = (input) => {
            tapLikeUser(input);

            if (input.tagName === 'TEXTAREA' || input.tagName === 'INPUT') {
              setNativeValue(input, text);
              input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
              input.dispatchEvent(new Event('change', { bubbles: true }));
              return input.value === text || input.value.length > 0;
            }

            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(input);
            range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);

            const inserted = document.execCommand && document.execCommand('insertText', false, text);
            if (!inserted) {
              input.textContent = text;
              input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            }

            return (input.innerText || input.textContent || '').length > 0;
          };

          const directInput = findComposer();
          if (directInput && insertInto(directInput)) return true;

          const composerShell = Array.from(document.querySelectorAll('form, [data-testid="composer"], main'))
            .reverse()
            .find(visible);
          if (composerShell) {
            tapLikeUser(composerShell);
            const retryInput = findComposer();
            if (retryInput && insertInto(retryInput)) return true;
          }

          return false;
        })();
        """

        let value = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }

        return (value as? Bool) == true
    }

    func userMessageCount() async -> Int {
        let script = #"""
        (() => document.querySelectorAll('[data-message-author-role="user"]').length)();
        """#

        let value = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }

        if let intValue = value as? Int { return intValue }
        if let numberValue = value as? NSNumber { return numberValue.intValue }
        return 0
    }
}
