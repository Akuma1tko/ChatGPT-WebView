extension ProviderConversationExtractionScript {
    static let scriptPart2 = #"""
                const code = (element.querySelector?.('code')?.innerText || element.innerText || element.textContent || '').replace(/\u00a0/g,' ').trimEnd();
                const fence = fenceFor(code);
                return `\n\n${fence}\n${code}\n${fence}\n\n`;
              }
              if (tag === 'table') return `\n\n${tableMD(element)}\n\n`;
              if (tag === 'a') {
                const href = String(element.href || element.getAttribute('href') || '').trim();
                const label = normalizeMarkdown(renderChildren(element) || href).replace(/[\[\]]/g,'');
                if (!href || /^(javascript|data|vbscript):/i.test(href)) return label;
                return `[${label}](${href.replace(/\)/g,'%29')})`;
              }
              if (['img','canvas','video','audio'].includes(tag)) return `[${tag}]`;
              if (/^h[1-6]$/.test(tag)) {
                const level = Number(tag.slice(1));
                return `\n\n${'#'.repeat(level)} ${normalizeMarkdown(renderChildren(element))}\n\n`;
              }
              if (tag === 'ul' || tag === 'ol') return `\n\n${renderList(element)}\n\n`;
              if (tag === 'blockquote') {
                const quote = normalizeMarkdown(renderChildren(element));
                return `\n\n${quote.split('\n').map(line => `> ${line}`).join('\n')}\n\n`;
              }
              if (tag === 'hr') return '\n\n---\n\n';
              if (tag === 'code') {
                const code = String(element.innerText || element.textContent || '').replace(/\u00a0/g,' ');
                const fence = inlineFenceFor(code);
                return `${fence}${code}${fence}`;
              }
              if (tag === 'strong' || tag === 'b') return `**${normalizeMarkdown(renderChildren(element))}**`;
              if (tag === 'em' || tag === 'i') return `*${normalizeMarkdown(renderChildren(element))}*`;
              const content = renderChildren(element);
              let display = '';
              try { display = getComputedStyle(element).display; } catch (_) {}
              return blockDisplays.has(display) ? `\n\n${content}\n\n` : content;
            };
            const renderChildren = node => Array.from(node.childNodes).map(renderNode).join('');
            return normalizeMarkdown(renderChildren(root));
          };
          const pushTurn = (turns, seen, role, content, preserveMarkdown = false) => {
            const value = preserveMarkdown ? normalizeMarkdown(content) : normalize(content);
            if (!['user','assistant'].includes(role) || value.length < 5 || value.length >= 300000 || isInterstitial(value)) return false;
            const key = `${role}:${value.slice(0,220)}`;
            if (seen.has(key)) return false;
            seen.add(key);
            turns.push({ role, content: value });
            return true;
          };
          const hasBothRoles = turns => turns.some(turn => turn.role === 'user') && turns.some(turn => turn.role === 'assistant');
          const diagnostics = (strategy, expectedCanaries, matchedCanaries, usedFallback = false, unclassifiedCandidateCount = 0) => ({
            strategyVersion: 1,
            strategy,
            expectedCanaries,
            matchedCanaries,
            usedFallback,
            challengeDetected: false,
            unclassifiedCandidateCount
          });
          const extractChatGPT = () => {
            const turns = [], seen = new Set();
            const nodes = topLevel(all(document, '[data-message-author-role]'));
            let unclassified = 0;
            nodes.forEach(node => {
              const role = String(node.getAttribute('data-message-author-role') || '').toLowerCase();
              if (!['user','assistant'].includes(role)) unclassified += 1;
              pushTurn(turns, seen, role, serialize(node));
            });
            return {
              turns,
              diagnostics: diagnostics(
                'chatgpt-explicit-author-role',
                ['data-message-author-role'],
                nodes.length > 0 ? ['data-message-author-role'] : [],
                false,
                unclassified
              )
            };
          };
          const extractClaude = () => {
            const turnSelector = [
              '[data-testid^="conversation-turn-"]',
              '[data-testid*="conversation-turn"]',
              '[class*="ConversationTurn"]',
              '[class*="message-row"]',
              '[class*="MessageRow"]',
              '[data-test-render-count]'
            ].join(',');
            const userSelector = [
              '[data-message-author-role="user"]',
              '[data-testid="user-message"]',
              '[data-testid*="user-message"]',
              '.font-user-message',
              '[data-testid*="human-message"]',
              '[data-testid*="human-turn"]'
            ].join(',');
            const assistantSelector = [
              '[data-message-author-role="assistant"]',
              '.font-claude-response',
              '.font-claude-response-body',
              '[data-testid="chat-message-text"]',
              '[data-testid*="chat-message-text"]',
              '[data-testid*="assistant-message"]',
              '[data-testid*="assistant-turn"]',
              '.progressive-markdown',
              '.standard-markdown'
            ].join(',');
            const assistantHeadingSelector = 'h1[data-find-omitted],h2[data-find-omitted],h3[data-find-omitted]';
            const composerSelector = 'form,textarea,[contenteditable="true"],[data-testid*="composer"],[data-testid*="input"],footer';
            const isWithinComposer = node => Boolean(node.closest?.(composerSelector));
            const usable = node => !isWithinComposer(node) && text(node).length >= 5;
            const explicitUserNodes = documentOrder(deepest(allDeep(document, userSelector).filter(usable)));
            const explicitAssistantNodes = documentOrder(deepest(allDeep(document, assistantSelector).filter(node => {
              if (!usable(node)) return false;
              return !node.closest?.(userSelector);
            })));
            const responseHeadings = documentOrder(allDeep(document, assistantHeadingSelector).filter(heading => {
              return !isWithinComposer(heading) && /^Claude responded:/i.test(text(heading));
            }));
            const rows = documentOrder(deepest(allDeep(document, turnSelector).filter(usable)));
            const expectedCanaries = ['claude-turn-container','claude-user-role-evidence','claude-assistant-role-evidence'];
            const matchedCanaries = [];
            if (rows.length > 0) matchedCanaries.push('claude-turn-container');
            if (explicitUserNodes.length > 0) matchedCanaries.push('claude-user-role-evidence');
            if (explicitAssistantNodes.length > 0 || responseHeadings.length > 0) matchedCanaries.push('claude-assistant-role-evidence');

            const primaryTurns = [], primarySeen = new Set();
            let unclassified = 0;
            rows.forEach(row => {
              const rowUsers = deepest(allDeep(row, userSelector).filter(usable));
              const rowAssistants = deepest(allDeep(row, assistantSelector).filter(node => {
                if (!usable(node)) return false;
                return !node.closest?.(userSelector);
              }));
              const rowHasAssistantHeading = allDeep(row, assistantHeadingSelector).some(heading => {
                return /^Claude responded:/i.test(text(heading));
              });

              if (rowUsers.length > 0 && rowAssistants.length === 0 && !rowHasAssistantHeading) {
                const content = rowUsers.map(serialize).filter(Boolean).join('\n\n');
                pushTurn(primaryTurns, primarySeen, 'user', content);
                return;
              }
              if (rowAssistants.length > 0 && rowUsers.length === 0) {
                const content = rowAssistants.map(serialize).filter(Boolean).join('\n\n');
                pushTurn(primaryTurns, primarySeen, 'assistant', content);
                return;
              }
        """#
}
