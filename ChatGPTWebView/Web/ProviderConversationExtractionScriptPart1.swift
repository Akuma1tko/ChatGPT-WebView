extension ProviderConversationExtractionScript {
    static let scriptPart1 = #"""
        (() => {
          const providerID = __CONTEXTPORT_PROVIDER_IDS__[0];
          const providerName = __CONTEXTPORT_PROVIDER_NAMES__[0];
          const providerStartURL = __CONTEXTPORT_PROVIDER_URLS__[0];
          const normalize = v => String(v || '').replace(/\u00a0/g,' ').replace(/\r\n?/g,'\n').replace(/[ \t]+\n/g,'\n').replace(/\n[ \t]+/g,'\n').replace(/\n{3,}/g,'\n\n').trim();
          const normalizeMarkdown = v => String(v || '').replace(/\u00a0/g,' ').replace(/\r\n?/g,'\n').replace(/[ \t]+\n/g,'\n').replace(/\n{3,}/g,'\n\n').trim();
          const all = (root, selector) => { try { return Array.from(root.querySelectorAll(selector)); } catch { return []; } };
          const allDeep = (root, selector) => {
            const roots = [root];
            const visited = new Set([root]);
            const matches = [];
            for (let index = 0; index < roots.length; index += 1) {
              const searchRoot = roots[index];
              if (searchRoot !== document && searchRoot.matches?.(selector)) matches.push(searchRoot);
              matches.push(...all(searchRoot, selector));
              all(searchRoot, '*').forEach(element => {
                if (element.shadowRoot && !visited.has(element.shadowRoot)) {
                  visited.add(element.shadowRoot);
                  roots.push(element.shadowRoot);
                }
              });
            }
            return Array.from(new Set(matches));
          };
          const text = el => normalize(el ? (el.innerText || el.textContent || '') : '');
          const topLevel = items => items.filter((item, index) => !items.some((other, otherIndex) => otherIndex !== index && other.contains(item)));
          const deepest = items => items.filter((item, index) => !items.some((other, otherIndex) => otherIndex !== index && item.contains(other)));
          const documentOrder = items => [...items].sort((left, right) => {
            if (left === right) return 0;
            return left.compareDocumentPosition(right) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
          });
          const interstitialMarkers = [/__CF\$cv\$params/i,/\/cdn-cgi\/challenge-platform\//i,/cf-turnstile/i,/challenge-platform\/scripts/i];
          const isInterstitial = value => interstitialMarkers.some(pattern => pattern.test(String(value || '')));
          const title = (() => {
            for (const selector of ['h1:not([class*=hidden])','[data-testid*=conversation-title]','[class*=conversation-title]','[aria-label*=conversation][aria-label*=title]']) {
              const value = normalize(document.querySelector(selector)?.textContent || '');
              if (value && ![providerName.toLowerCase(),'new chat','untitled','chat'].includes(value.toLowerCase())) return value;
            }
            let doc = normalize(document.title || '');
            const lower = doc.toLowerCase();
            const providerLower = providerName.toLowerCase();
            for (const separator of [' - ', ' | ']) {
              const suffix = separator + providerLower;
              if (lower.endsWith(suffix)) {
                doc = doc.slice(0, doc.length - suffix.length).trim();
                break;
              }
            }
            return doc && ![providerLower,'new chat','untitled','chat'].includes(doc.toLowerCase())
              ? doc
              : `${providerName} Conversation`;
          })();
          const fenceFor = code => '`'.repeat(((String(code).match(/`{3,}/g) || []).reduce((m, r) => Math.max(m, r.length), 2)) + 1);
          const tableMD = table => {
            const rows = Array.from(table.querySelectorAll('tr')).map(row => Array.from(row.children).filter(cell => ['TH','TD'].includes(cell.tagName)).map(cell => normalize(cell.innerText || cell.textContent || '').replace(/\|/g,'\\|') || ' ')).filter(row => row.length);
            if (!rows.length) return text(table);
            const width = Math.max(...rows.map(row => row.length));
            const filled = rows.map(row => row.concat(Array(Math.max(0, width - row.length)).fill(' ')));
            return [`| ${filled[0].join(' | ')} |`,`| ${filled[0].map(() => '---').join(' | ')} |`,...filled.slice(1).map(row => `| ${row.join(' | ')} |`)].join('\n');
          };
          const serialize = root => {
            const clone = root.cloneNode(true);
            all(clone, 'button,svg,style,script,textarea,input,[contenteditable=true],[aria-label*=Copy],[aria-label*=More],[data-testid*=copy],[class*=sr-only],[class*=visually-hidden]').forEach(node => node.remove());
            topLevel(all(clone, 'pre,code-block,[data-testid*=code-block]')).forEach(block => { const code = (block.querySelector?.('code')?.innerText || block.innerText || block.textContent || '').replace(/\u00a0/g,' ').trimEnd(); const fence = fenceFor(code); block.replaceWith(document.createTextNode(`\n\n${fence}\n${code}\n${fence}\n\n`)); });
            topLevel(all(clone, 'table')).forEach(table => table.replaceWith(document.createTextNode(`\n\n${tableMD(table)}\n\n`)));
            all(clone, 'a[href]').forEach(link => { const href = String(link.href || link.getAttribute('href') || '').trim(); if (!href || /^(javascript|data|vbscript):/i.test(href)) return; const label = normalize(link.innerText || link.textContent || href).replace(/[\[\]]/g,''); link.replaceWith(document.createTextNode(`[${label}](${href.replace(/\)/g,'%29')})`)); });
            all(clone, 'img,canvas,video,audio').forEach(media => media.replaceWith(document.createTextNode(`[${media.tagName.toLowerCase()}]`)));
            return text(clone);
          };
          const serializeDeepSeek = root => {
            const noiseSelector = 'button,svg,style,script,textarea,input,[contenteditable=true],[aria-label*=Copy],[aria-label*=More],[data-testid*=copy],[class*=sr-only],[class*=visually-hidden]';
            const blockDisplays = new Set(['block','flow-root','flex','grid','list-item','table','table-row-group','table-header-group','table-footer-group']);
            const inlineFenceFor = code => '`'.repeat(((String(code).match(/`+/g) || []).reduce((m, r) => Math.max(m, r.length), 0)) + 1);
            const renderList = (list, depth = 0) => {
              const ordered = list.tagName === 'OL';
              const start = Number.parseInt(list.getAttribute('start') || '1', 10) || 1;
              return Array.from(list.children).filter(item => item.tagName === 'LI').map((item, index) => {
                const content = Array.from(item.childNodes)
                  .filter(node => !(node.nodeType === Node.ELEMENT_NODE && ['UL','OL'].includes(node.tagName)))
                  .map(renderNode)
                  .join('');
                const prefix = ordered ? `${start + index}.` : '-';
                const line = `${'  '.repeat(depth)}${prefix} ${normalizeMarkdown(content)}`;
                const nested = Array.from(item.children)
                  .filter(child => ['UL','OL'].includes(child.tagName))
                  .map(child => renderList(child, depth + 1))
                  .filter(Boolean)
                  .join('\n');
                return nested ? `${line}\n${nested}` : line;
              }).join('\n');
            };
            const renderNode = node => {
              if (node.nodeType === Node.TEXT_NODE) return String(node.nodeValue || '').replace(/\u00a0/g,' ');
              if (node.nodeType !== Node.ELEMENT_NODE) return '';
              const element = node;
              if (element.matches?.(noiseSelector)) return '';
              const tag = element.tagName.toLowerCase();
              if (tag === 'br') return '\n';
              if (tag === 'pre' || tag === 'code-block' || element.matches?.('[data-testid*=code-block]')) {
        """#
}
