import Foundation
import WebKit

private let developerInlineSourceChunkCharacters = 64 * 1024
private let developerMaximumInlineSourceCharacters = 4 * 1024 * 1024

func loadDeveloperInlineSourceFiles(
    from descriptors: [DeveloperDiscoveredSource],
    session: DeveloperWebViewSession,
    pageURL: String
) async -> [DeveloperSourceFile] {
    var files: [DeveloperSourceFile] = []

    for descriptor in descriptors {
        guard !Task.isCancelled else { return files }

        if let inlineSource = descriptor.inlineSource {
            files.append(
                DeveloperSourceFile(
                    id: "\(session.id)::\(descriptor.key)",
                    sessionTitle: session.title,
                    pageURL: pageURL,
                    displayName: descriptor.displayName,
                    urlString: descriptor.url,
                    kind: descriptor.kind,
                    content: inlineSource,
                    metadataNote: nil,
                    resourceByteCount: nil,
                    loadError: nil
                )
            )
            continue
        }

        guard let scriptIndex = descriptor.inlineSourceIndex else { continue }
        files.append(
            await loadDeveloperInlineScript(
                descriptor: descriptor,
                scriptIndex: scriptIndex,
                session: session,
                pageURL: pageURL
            )
        )

        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return files
}

private func loadDeveloperInlineScript(
    descriptor: DeveloperDiscoveredSource,
    scriptIndex: Int,
    session: DeveloperWebViewSession,
    pageURL: String
) async -> DeveloperSourceFile {
    let sourceID = "\(session.id)::\(descriptor.key)"
    let reportedCharacterCount = descriptor.inlineSourceCharacterCount ?? 0

    guard reportedCharacterCount <= developerMaximumInlineSourceCharacters else {
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: session.title,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: descriptor.url,
            kind: descriptor.kind,
            content: nil,
            metadataNote: "Inline script text was not retained because the page reported \(reportedCharacterCount) UTF-16 characters, above ContextPort's 4 MB live-WebView capture budget.",
            resourceByteCount: nil,
            loadError: nil
        )
    }

    do {
        let lengthScript = """
        (() => {
          const script = document.scripts[\(scriptIndex)];
          if (!script || script.src) return -1;
          return String(script.textContent || '').length;
        })();
        """
        let rawLength = try await session.webView.evaluateJavaScript(lengthScript)
        guard let number = rawLength as? NSNumber else {
            throw DeveloperSourceInlineReadError.scriptUnavailable
        }

        let characterCount = number.intValue
        guard characterCount >= 0 else {
            throw DeveloperSourceInlineReadError.scriptUnavailable
        }
        guard characterCount <= developerMaximumInlineSourceCharacters else {
            return DeveloperSourceFile(
                id: sourceID,
                sessionTitle: session.title,
                pageURL: pageURL,
                displayName: descriptor.displayName,
                urlString: descriptor.url,
                kind: descriptor.kind,
                content: nil,
                metadataNote: "Inline script text was not retained because the live page contains \(characterCount) UTF-16 characters, above ContextPort's 4 MB live-WebView capture budget.",
                resourceByteCount: nil,
                loadError: nil
            )
        }

        var data = Data()
        data.reserveCapacity(min(characterCount * 2, developerMaximumInlineSourceCharacters * 2))

        var start = 0
        while start < characterCount {
            guard !Task.isCancelled else {
                throw CancellationError()
            }

            let end = min(start + developerInlineSourceChunkCharacters, characterCount)
            let chunkScript = """
            (() => {
              const script = document.scripts[\(scriptIndex)];
              if (!script || script.src) return null;
              return String(script.textContent || '').slice(\(start), \(end));
            })();
            """
            let rawChunk = try await session.webView.evaluateJavaScript(chunkScript)
            guard let chunk = rawChunk as? String else {
                throw DeveloperSourceInlineReadError.scriptUnavailable
            }

            data.append(contentsOf: chunk.utf8)
            start = end

            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw DeveloperSourceInlineReadError.invalidUTF8
        }

        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: session.title,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: descriptor.url,
            kind: descriptor.kind,
            content: content,
            metadataNote: "Inline script text was read from the live WebView in 64 KB character chunks to bound transient capture memory.",
            resourceByteCount: nil,
            loadError: nil
        )
    } catch is CancellationError {
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: session.title,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: descriptor.url,
            kind: descriptor.kind,
            content: nil,
            metadataNote: "Inline script capture was cancelled before the complete source body was retained.",
            resourceByteCount: nil,
            loadError: nil
        )
    } catch {
        return DeveloperSourceFile(
            id: sourceID,
            sessionTitle: session.title,
            pageURL: pageURL,
            displayName: descriptor.displayName,
            urlString: descriptor.url,
            kind: descriptor.kind,
            content: nil,
            metadataNote: nil,
            resourceByteCount: nil,
            loadError: error.localizedDescription
        )
    }
}

func discoverDeveloperSources(in webView: WKWebView) async throws -> DeveloperDiscoveredPage {
    let script = #"""
    (() => {
        const sources = [];
        const seen = new Set();

        const displayName = (url, fallback) => {
            try {
                const parsed = new URL(url, document.baseURI);
                const name = parsed.pathname.split('/').filter(Boolean).pop();
                return name || fallback || parsed.hostname;
            } catch (_) {
                return fallback || url;
            }
        };

        const classifyResource = (url, initiatorType) => {
            const clean = String(url || '').split('#')[0].toLowerCase();
            if (/\.css(?:$|\?)/i.test(clean)) return 'Stylesheet';
            if (/\.map(?:$|\?)/i.test(clean)) return 'Source Map';
            if (/\.wasm(?:$|\?)/i.test(clean)) return 'WebAssembly Binary';
            if (initiatorType === 'worker') return 'Worker JavaScript';
            if (initiatorType === 'script') return 'JavaScript';
            return 'Runtime Resource';
        };

        const addExternal = (rawURL, kind, fallbackName) => {
            if (!rawURL) return;

            let absoluteURL = rawURL;
            try {
                absoluteURL = new URL(rawURL, document.baseURI).href;
            } catch (_) {}

            if (!/^https?:/i.test(absoluteURL) || seen.has(absoluteURL)) return;
            seen.add(absoluteURL);
            sources.push({
                key: `external:${absoluteURL}`,
                displayName: displayName(absoluteURL, fallbackName),
                url: absoluteURL,
                kind,
                inlineSource: null,
                inlineSourceIndex: null,
                inlineSourceCharacterCount: null
            });
        };

        Array.from(document.scripts).forEach((script, index) => {
            if (script.src) {
                addExternal(script.src, 'JavaScript', `Script ${index + 1}`);
                return;
            }

            const characterCount = String(script.textContent || '').length;
            if (characterCount === 0) return;

            sources.push({
                key: `inline-script:${index}`,
                displayName: `Inline Script ${index + 1}`,
                url: null,
                kind: 'Inline JavaScript',
                inlineSource: null,
                inlineSourceIndex: index,
                inlineSourceCharacterCount: characterCount
            });
        });

        Array.from(document.querySelectorAll('link[href]')).forEach((link, index) => {
            const rel = String(link.rel || '').toLowerCase();
            const as = String(link.as || '').toLowerCase();
            const href = link.href;
            if (!href) return;

            if (rel.split(/\s+/).includes('stylesheet')) {
                addExternal(href, 'Stylesheet', `Stylesheet ${index + 1}`);
            } else if (rel.split(/\s+/).includes('modulepreload')) {
                addExternal(href, 'JavaScript Module Preload', `Module Preload ${index + 1}`);
            } else if (rel.split(/\s+/).includes('preload') && ['script', 'style', 'worker'].includes(as)) {
                addExternal(href, classifyResource(href, as), `Preload ${index + 1}`);
            }
        });

        try {
            performance.getEntriesByType('resource').forEach((entry) => {
                const type = String(entry.initiatorType || '').toLowerCase();
                const supportedType = ['script', 'link', 'worker'].includes(type);
                const supportedExtension = /\.(?:m?js|cjs|css|map|wasm)(?:$|\?)/i.test(entry.name || '');
                if (supportedType || supportedExtension) {
                    addExternal(entry.name, classifyResource(entry.name, type), 'Runtime Resource');
                }
            });
        } catch (_) {}

        return JSON.stringify({
            pageURL: location.href,
            sources
        });
    })();
    """#

    let value = try await webView.evaluateJavaScript(script)
    guard let json = value as? String,
          let data = json.data(using: .utf8) else {
        throw DeveloperSourceScanError.invalidInventory
    }

    return try JSONDecoder().decode(DeveloperDiscoveredPage.self, from: data)
}

private enum DeveloperSourceInlineReadError: LocalizedError {
    case scriptUnavailable
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .scriptUnavailable:
            return "The inline script changed or disappeared before ContextPort could finish its bounded read."
        case .invalidUTF8:
            return "The inline script could not be retained as UTF-8 text."
        }
    }
}

private enum DeveloperSourceScanError: LocalizedError {
    case invalidInventory

    var errorDescription: String? {
        switch self {
        case .invalidInventory:
            return "The page did not return a readable source inventory."
        }
    }
}
