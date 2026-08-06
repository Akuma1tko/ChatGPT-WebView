extension ProviderConversationExtractionScript {
    static let scriptPart3 = #"""
              if (rowHasAssistantHeading && rowUsers.length === 0) {
                pushTurn(primaryTurns, primarySeen, 'assistant', serialize(row));
                return;
              }
              unclassified += 1;
            });

            if (hasBothRoles(primaryTurns)) {
              return {
                turns: primaryTurns,
                diagnostics: diagnostics(
                  'claude-explicit-turn-containers-v2',
                  expectedCanaries,
                  matchedCanaries,
                  false,
                  unclassified
                )
              };
            }

            const candidates = [];
            explicitUserNodes.forEach(node => {
              candidates.push({ node, role: 'user', content: serialize(node) });
            });
            explicitAssistantNodes.forEach(node => {
              candidates.push({ node, role: 'assistant', content: serialize(node) });
            });
            responseHeadings.forEach(heading => {
              const root = heading.parentElement || heading;
              const responseBlocks = deepest(allDeep(root, assistantSelector).filter(node => {
                if (!usable(node)) return false;
                return !node.closest?.(userSelector);
              }));
              candidates.push({
                node: root,
                role: 'assistant',
                content: responseBlocks.length > 0
                  ? responseBlocks.map(serialize).filter(Boolean).join('\n\n')
                  : serialize(root)
              });
            });
            candidates.sort((left, right) => {
              if (left.node === right.node) return 0;
              return left.node.compareDocumentPosition(right.node) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
            });

            const fallbackTurns = [], fallbackSeen = new Set();
            candidates.forEach(candidate => pushTurn(fallbackTurns, fallbackSeen, candidate.role, candidate.content));
            return {
              turns: fallbackTurns,
              diagnostics: diagnostics(
                'claude-direct-explicit-role-evidence-v2',
                expectedCanaries,
                matchedCanaries,
                true,
                unclassified
              )
            };
          };
          const extractGrok = () => {
            const turns = [], seen = new Set();
            const userNodes = topLevel(all(document, '[data-testid="user-message"]'));
            const assistantNodes = topLevel(all(document, '[data-testid="assistant-message"]'));
            const nodes = topLevel(all(document, '[data-testid="user-message"],[data-testid="assistant-message"]'));
            nodes.forEach(node => {
              const testID = String(node.getAttribute('data-testid') || '').toLowerCase();
              const role = testID === 'user-message' ? 'user' : testID === 'assistant-message' ? 'assistant' : '';
              pushTurn(turns, seen, role, serialize(node));
            });
            const matchedCanaries = [];
            if (userNodes.length > 0) matchedCanaries.push('user-message');
            if (assistantNodes.length > 0) matchedCanaries.push('assistant-message');
            return {
              turns,
              diagnostics: diagnostics(
                'grok-message-testids',
                ['user-message','assistant-message'],
                matchedCanaries
              )
            };
          };
          const extractDeepSeek = () => {
            const rowSelector = '[data-virtual-list-item-key]';
            const userWrapperSelector = '.ds-message.d29f3d7d';
            const userBodySelector = '.fbb737a4';
            const assistantBodySelector = '.ds-assistant-message-main-content';
            const rows = topLevel(all(document, rowSelector));
            const userBodies = topLevel(all(document, `${rowSelector} ${userWrapperSelector} ${userBodySelector}`));
            const assistantBodies = topLevel(all(document, `${rowSelector} ${assistantBodySelector}`));
            const expectedCanaries = ['virtual-list-item-key','deepseek-user-renderer','deepseek-assistant-content'];
            const matchedCanaries = [];
            if (rows.length > 0) matchedCanaries.push('virtual-list-item-key');
            if (userBodies.length > 0) matchedCanaries.push('deepseek-user-renderer');
            if (assistantBodies.length > 0) matchedCanaries.push('deepseek-assistant-content');

            const turns = [], seen = new Set();
            let unclassified = 0;
            rows.forEach(row => {
              const rowUserBodies = topLevel(all(row, `${userWrapperSelector} ${userBodySelector}`));
              const rowAssistantBodies = topLevel(all(row, assistantBodySelector));
              if (rowUserBodies.length > 0 && rowAssistantBodies.length === 0) {
                const content = rowUserBodies.map(serializeDeepSeek).filter(Boolean).join('\n\n');
                pushTurn(turns, seen, 'user', content, true);
                return;
              }
              if (rowAssistantBodies.length > 0 && rowUserBodies.length === 0) {
                const content = rowAssistantBodies.map(serializeDeepSeek).filter(Boolean).join('\n\n');
                pushTurn(turns, seen, 'assistant', content, true);
                return;
              }
              if (topLevel(all(row, '.ds-message')).length > 0 || text(row).length >= 5) unclassified += 1;
            });
            return {
              turns,
              diagnostics: diagnostics(
                'deepseek-virtual-row-role-renderers',
                expectedCanaries,
                matchedCanaries,
                false,
                unclassified
              )
            };
          };
          const extractGemini = () => {
            const turns = [], seen = new Set();
            const userSelector = 'user-query,[data-message-author-role="user"],[data-test-id="user-query"],[data-testid="user-query"]';
            const assistantSelector = 'model-response,[data-message-author-role="assistant"],[data-test-id="model-response"],[data-testid="model-response"]';
            const selectors = `${userSelector},${assistantSelector}`;
            const userNodes = topLevel(all(document, userSelector));
            const assistantNodes = topLevel(all(document, assistantSelector));
            topLevel(all(document, selectors)).forEach(node => {
              const explicitRole = String(node.getAttribute('data-message-author-role') || '').toLowerCase();
              const identity = [node.tagName,node.getAttribute('data-test-id'),node.getAttribute('data-testid')].filter(Boolean).join(' ').toLowerCase();
              const role = explicitRole === 'user' || /user-query/.test(identity)
                ? 'user'
                : explicitRole === 'assistant' || /model-response/.test(identity)
                  ? 'assistant'
                  : '';
              pushTurn(turns, seen, role, serialize(node));
            });
            const matchedCanaries = [];
            if (userNodes.length > 0) matchedCanaries.push('user-query');
            if (assistantNodes.length > 0) matchedCanaries.push('model-response');
            return {
              turns,
              diagnostics: diagnostics(
                'gemini-explicit-turn-evidence',
                ['user-query','model-response'],
                matchedCanaries
              )
            };
          };
          const extractor = {
            chatgpt: extractChatGPT,
            claude: extractClaude,
            gemini: extractGemini,
            grok: extractGrok,
            deepseek: extractDeepSeek
          }[providerID];
          const extraction = extractor
            ? extractor()
            : { turns: [], diagnostics: diagnostics('unsupported-provider', ['supported-provider'], []) };
          const turns = extraction.turns;
          const exportedAt = new Date().toISOString();
          const source = window.location.href || providerStartURL;
          const pageHasInterstitial = isInterstitial(document.documentElement?.innerHTML || '') || isInterstitial(text(document.body));
          const blockingChallengeDetected = turns.length === 0 && pageHasInterstitial;
        """#
}
