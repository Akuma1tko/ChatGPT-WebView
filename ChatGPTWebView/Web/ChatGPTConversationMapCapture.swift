import Foundation
import WebKit

struct ChatGPTConversationMapCaptureResult {
    let payloadJSON: String?
    let isConversationRoute: Bool
}

@MainActor
enum ChatGPTConversationMapCapture {
    static func capture(from webView: WKWebView) async throws -> ChatGPTConversationMapCaptureResult {
        guard let url = webView.url,
              let conversationID = conversationID(from: url) else {
            return ChatGPTConversationMapCaptureResult(
                payloadJSON: nil,
                isConversationRoute: false
            )
        }

        let value = try await callAsyncJavaScript(
            captureScript,
            arguments: ["conversationID": conversationID],
            in: webView
        )
        return ChatGPTConversationMapCaptureResult(
            payloadJSON: value as? String,
            isConversationRoute: true
        )
    }

    private static func conversationID(from url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let conversationIndex = components.firstIndex(of: "c"),
              components.indices.contains(conversationIndex + 1) else {
            return nil
        }

        let candidate = components[conversationIndex + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 8 else { return nil }
        return candidate
    }

    private static func callAsyncJavaScript(
        _ script: String,
        arguments: [String: Any],
        in webView: WKWebView
    ) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                in: .page
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static let captureScript = #"""
    return await (async () => {
      const normalize = value => String(value || '')
        .replace(/\u00a0/g, ' ')
        .replace(/\r\n?/g, '\n')
        .replace(/[ \t]+\n/g, '\n')
        .replace(/\n[ \t]+/g, '\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
      const pageURL = String(location.href || 'https://chatgpt.com/');
      const expectedCanaries = ['chatgpt-active-branch', 'chatgpt-provider-transport'];
      const diagnostics = (strategy, matchedCanaries) => ({
        strategyVersion: 3,
        strategy,
        expectedCanaries,
        matchedCanaries,
        usedFallback: false,
        challengeDetected: false,
        unclassifiedCandidateCount: 0
      });
      const titleFromDocument = () => {
        const heading = document.querySelector('h1:not([class*=hidden])');
        const headingText = normalize(heading?.textContent || '');
        if (headingText && !['chatgpt', 'new chat', 'untitled', 'chat'].includes(headingText.toLowerCase())) {
          return headingText;
        }
        let value = normalize(document.title || '');
        value = value.replace(/\s[-|]\sChatGPT$/i, '').trim();
        return value && !['chatgpt', 'new chat', 'untitled', 'chat'].includes(value.toLowerCase())
          ? value
          : 'ChatGPT Conversation';
      };
      const renderPart = part => {
        if (typeof part === 'string') return part;
        if (!part || typeof part !== 'object') return '';
        if (typeof part.text === 'string') return part.text;
        if (typeof part.content === 'string') return part.content;
        if (Array.isArray(part.parts)) return part.parts.map(renderPart).filter(Boolean).join('\n');
        const type = String(part.content_type || '').toLowerCase();
        if (type.includes('image')) return '[image]';
        if (type.includes('audio')) return '[audio]';
        if (type.includes('video')) return '[video]';
        return '';
      };
      const visibleTurn = message => {
        if (!message || typeof message !== 'object') return null;
        const role = String(message.author?.role || '').toLowerCase();
        if (role !== 'user' && role !== 'assistant') return null;
        const metadata = message.metadata || {};
        if (metadata.is_visually_hidden_from_conversation === true) return null;
        if (role === 'user' && metadata.is_user_system_message === true) return null;
        if (role === 'assistant') {
          const channel = String(message.channel || '').toLowerCase();
          const recipient = String(message.recipient || '').toLowerCase();
          if (channel && channel !== 'final') return null;
          if (recipient && recipient !== 'all') return null;
          if (metadata.reasoning_status != null) return null;
        }
        const contentType = String(message.content?.content_type || '').toLowerCase();
        const parts = Array.isArray(message.content?.parts) ? message.content.parts : [];
        const renderedParts = parts.map(renderPart).filter(Boolean);
        let content = contentType === 'text'
          ? renderedParts.join('')
          : renderedParts.join('\n\n');
        if (!content && typeof message.content?.text === 'string') content = message.content.text;
        content = normalize(content);
        if (content.length < 5 || content.length >= 300000) return null;
        return { id: String(message.id || ''), role, content };
      };
      const turnsFromMessages = messages => {
        const turns = [];
        const seenMessageIDs = new Set();
        for (const message of messages) {
          const turn = visibleTurn(message);
          if (!turn) continue;
          if (turn.id && seenMessageIDs.has(turn.id)) continue;
          if (turn.id) seenMessageIDs.add(turn.id);
          turns.push({ role: turn.role, content: turn.content });
        }
        return turns;
      };
      const hasBothRoles = turns => turns.some(turn => turn.role === 'user')
        && turns.some(turn => turn.role === 'assistant');
      const payload = (title, turns, strategy, matchedCanaries, error = null) => JSON.stringify({
        title: normalize(title) || titleFromDocument(),
        turns,
        sourceURL: pageURL,
        exportedAt: new Date().toISOString(),
        error,
        diagnostics: diagnostics(strategy, matchedCanaries)
      });
      const fetchJSONURL = async (url, authorization = null) => {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 15000);
        try {
          const headers = { Accept: 'application/json' };
          if (authorization) headers.Authorization = `Bearer ${authorization}`;
          const response = await fetch(url, {
            method: 'GET',
            credentials: 'include',
            cache: 'no-store',
            headers,
            signal: controller.signal
          });
          if (!response.ok) return null;
          const declaredLength = Number(response.headers.get('content-length') || 0);
          if (declaredLength > 64 * 1024 * 1024) return null;
          const body = await response.text();
          if (body.length > 64 * 1024 * 1024) return null;
          return JSON.parse(body);
        } catch (_) {
          return null;
        } finally {
          clearTimeout(timeout);
        }
      };
      const session = await fetchJSONURL(`${location.origin}/api/auth/session`);
      const accessToken = typeof session?.accessToken === 'string'
        ? session.accessToken.trim()
        : '';
      const fetchJSON = path => fetchJSONURL(
        `${location.origin}/backend-api${path}`,
        accessToken || null
      );

      const encodedConversationID = encodeURIComponent(String(conversationID || ''));
      if (!encodedConversationID) {
        return payload('ChatGPT Conversation', [], 'chatgpt-map-route-invalid', [], 'chatgpt-map-unavailable');
      }

      const firstPage = await fetchJSON(`/conversations/${encodedConversationID}?num_turns=100`);
      if (firstPage && Array.isArray(firstPage.messages)) {
        const pages = [firstPage.messages];
        const seenCursors = new Set();
        let pageInfo = firstPage.page_info || null;
        let cursor = pageInfo?.has_previous_page ? pageInfo.start_cursor : null;
        let pageCount = 1;

        while (cursor && pageCount < 200) {
          if (seenCursors.has(cursor)) {
            return payload(firstPage.title, [], 'chatgpt-paginated-active-branch', ['chatgpt-provider-transport'], 'chatgpt-map-incomplete');
          }
          seenCursors.add(cursor);
          const olderPage = await fetchJSON(`/conversations/${encodedConversationID}/messages?before=${encodeURIComponent(cursor)}&num_turns=100`);
          if (!olderPage || !Array.isArray(olderPage.messages)) {
            return payload(firstPage.title, [], 'chatgpt-paginated-active-branch', ['chatgpt-provider-transport'], 'chatgpt-map-incomplete');
          }
          pages.unshift(olderPage.messages);
          pageInfo = olderPage.page_info || null;
          cursor = pageInfo?.has_previous_page ? pageInfo.start_cursor : null;
          pageCount += 1;
        }

        if (cursor) {
          return payload(firstPage.title, [], 'chatgpt-paginated-active-branch', ['chatgpt-provider-transport'], 'chatgpt-map-incomplete');
        }

        const turns = turnsFromMessages(pages.flat());
        if (hasBothRoles(turns)) {
          return payload(
            firstPage.title,
            turns,
            'chatgpt-paginated-active-branch',
            ['chatgpt-active-branch', 'chatgpt-provider-transport']
          );
        }
      }

      const conversation = await fetchJSON(`/conversation/${encodedConversationID}`);
      if (conversation && conversation.mapping && typeof conversation.mapping === 'object' && conversation.current_node) {
        const activeBranchLeafToRoot = [];
        const seenNodeIDs = new Set();
        let nodeID = String(conversation.current_node || '');

        while (nodeID) {
          if (seenNodeIDs.has(nodeID)) {
            return payload(conversation.title, [], 'chatgpt-mapping-current-node', ['chatgpt-provider-transport'], 'chatgpt-map-incomplete');
          }
          seenNodeIDs.add(nodeID);
          const node = conversation.mapping[nodeID];
          if (!node) {
            return payload(conversation.title, [], 'chatgpt-mapping-current-node', ['chatgpt-provider-transport'], 'chatgpt-map-incomplete');
          }
          activeBranchLeafToRoot.push(node);
          nodeID = String(node.parent || '');
        }

        const messages = activeBranchLeafToRoot
          .reverse()
          .map(node => node.message)
          .filter(Boolean);
        const turns = turnsFromMessages(messages);
        if (hasBothRoles(turns)) {
          return payload(
            conversation.title,
            turns,
            'chatgpt-mapping-current-node',
            ['chatgpt-active-branch', 'chatgpt-provider-transport']
          );
        }
        return payload(conversation.title, [], 'chatgpt-mapping-current-node', ['chatgpt-active-branch', 'chatgpt-provider-transport'], 'chatgpt-map-incomplete');
      }

      return payload(titleFromDocument(), [], 'chatgpt-provider-map-unavailable', [], 'chatgpt-map-unavailable');
    })();
    """#
}
