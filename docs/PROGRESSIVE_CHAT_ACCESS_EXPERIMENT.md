# Progressive Chat Access and Long Chat Optimization Experiment

## Purpose

A long ChatGPT Work conversation can display useful content before the entire page, composer, connectors, and remaining application state finish initializing. ContextPort should prioritize immediate human access to the content that already exists instead of treating complete page readiness as a prerequisite for reading and scrolling.

This experiment separates three controls that were previously easy to confuse:

1. **Access buckets** control how long ContextPort continues attempting to recover a usable vertical scroll container while ChatGPT is still loading and replacing its document structure.
2. **Render buckets** control how many already loaded conversation messages remain visible in the DOM. Each render bucket represents five visible messages.
3. **Advanced optimization controls** change recovery timing, native WebView behavior, follow-latest behavior, scroll-target selection, visual rendering, media pressure, and diagnostics.

None of these settings directly changes the private RAM ceiling that iOS assigns to a WebKit content process.

## Phase 1: Access First

When a ChatGPT WebView attaches to the screen, ContextPort can immediately enable native touch and vertical scrolling. It does not have to wait for navigation completion, the composer, Work controls, connector initialization, or a recognized conversation-turn marker.

The recovery code searches for the best visible scrollable container and applies vertical scrolling behavior while preserving the current page and login state.

The default six access buckets reproduce the successful ContextPort 2.10.4 build 83 schedule:

| Bucket | Recovery time |
|---:|---:|
| 1 | 0.25 seconds |
| 2 | 0.75 seconds |
| 3 | 2 seconds |
| 4 | 5 seconds |
| 5 | 10 seconds |
| 6 | 16 seconds |

Additional experimental buckets extend recovery through 24, 32, 45, 60, 90, and 120 seconds. A newer settings change invalidates older scheduled attempts so multiple configurations do not continue competing.

## Render buckets

Long-chat optimization hides older rendered message elements without deleting the conversation or removing those messages from Save Context.

- 1 render bucket = 5 visible messages
- 5 render buckets = 25 visible messages
- 10 render buckets = 50 visible messages
- 20 render buckets = 100 visible messages

Progressive access does not destroy the long-chat performance manager. Access buckets and render buckets can therefore be tested independently.

## In-app settings

All controls are inside:

**ContextPort → Settings**

This is intentional because unsigned builds do not reliably expose an iOS Settings bundle.

### Optimization presets

- **Compatibility** disables ContextPort intervention so the provider page can be compared against an essentially unmodified WebView.
- **Balanced** uses the original six access buckets, five render buckets, native vertical stabilization, and the lightweight 500 ms follow loop.
- **Aggressive** uses more access attempts, two recovery passes, fewer visible messages, deferred media, reduced effects, and selective rendering optimizations.
- **Extreme** uses the latest-exchange window, all access buckets, repeated recovery, and the most invasive visual and media suppression controls.
- **Diagnostic** keeps rendering changes conservative while enabling target-selection and DOM-count logging.

A preset only sets values. Every control remains independently adjustable afterward.

### Recovery scheduling

The test panel exposes:

- recovery delay scale from 25% through 400%;
- one through three recovery passes;
- 5 through 120 seconds between passes;
- recovery when the WebView attaches;
- recovery when ContextPort returns to the foreground;
- recovery after an iOS memory warning;
- native scroll preparation on every scheduled attempt.

Repeated passes remain bounded. Each settings change increments a generation token so older schedules stop before acting on the page.

### Native WebView behavior

The test panel exposes:

- force native scrolling;
- directional lock;
- outer WebView bounce suppression;
- delayed content touches;
- vertical scroll indicator;
- horizontal scroll indicator.

ChatGPT normally scrolls inside its own DOM container, so the outer `WKWebView` and inner page behavior must be tested separately.

### Follow latest behavior

The test panel exposes:

- enable or disable Follow Latest;
- whether a new or restored route begins in follow mode;
- follow check interval from 250 through 3,000 ms;
- near-bottom threshold from 20 through 300 points;
- upward-scroll handoff threshold from 1 through 24 points;
- programmatic-scroll guard from 100 through 1,500 ms;
- optional maximum follow duration through 600 seconds, with zero meaning unlimited.

Short intervals react faster but add JavaScript work. Long intervals reduce page activity but may allow the active response to move out of view temporarily.

### Scroll-target detection

The test panel exposes:

- rescan when the cached target disappears;
- include or exclude the document roots;
- prefer or ignore conversation ownership during scoring;
- minimum target height from 80 through 600 points;
- minimum scroll range from 20 through 400 points.

Disabling rescans provides the lowest DOM-query overhead but can leave the page without a usable target when ChatGPT replaces its document structure.

### Rendering and media pressure

The test panel exposes:

- `content-visibility` on conversation turns;
- CSS containment on offscreen turns;
- lazy image loading and asynchronous decoding for offscreen turns;
- pausing offscreen audio and video;
- hiding embedded frames;
- hiding canvas content;
- disabling animations and transitions;
- removing blur, filters, text shadows, and box shadows;
- hiding the ChatGPT sidebar;
- hiding the ChatGPT header;
- applying content visibility to code blocks;
- maximum rendered image height;
- DOM optimization interval from 1 through 10 seconds.

These options are experimental and increasingly invasive. Hiding frames, canvases, the sidebar, or the header may remove provider controls or interactive results. Every configuration must be tested with Save Context, attachments, downloads, generated images, and active responses.

### Diagnostics

Optional diagnostics can log:

- selected scroll target and score;
- conversation-turn count;
- image count;
- frame count;
- audio and video count;
- scheduled recovery configuration.

Logging itself changes workload and should remain off during normal timing comparisons unless diagnostic evidence is required.

## Recommended test method

Change one control at a time unless testing a named preset. Press **Save Settings for Restart**, fully close ContextPort from the app switcher, reopen the same Work chat, and record:

- configuration or preset name;
- time when conversation text first becomes visible;
- time when the first user scroll succeeds;
- time when the newest message becomes visible;
- time when the active assistant response becomes visible;
- time when the composer becomes interactive;
- whether the page refreshes, becomes blank, or the WebContent process terminates;
- whether Save Context still captures older hidden messages;
- whether attachments, images, code blocks, tables, citations, and interactive content remain usable;
- total time before the chat becomes fully usable.

The primary metric is **time to first usable chat access**, followed by termination frequency and preservation of required provider behavior.

## Save Context observation

Physical testing has shown that pressing Save Context while the assistant is processing can briefly cause the newest message to materialize and become visible. This suggests that the authenticated conversation extraction path or the DOM activity it triggers changes what ChatGPT has materialized near the active branch.

This PR does not claim that Save Context adds RAM. The behavior should be measured separately because it may reveal a reliable way to request or preserve the active conversation branch without waiting for full UI hydration.

## Parallel child WebViews

Creating hidden child `WKWebView` instances is not included in this phase.

WebKit may assign separate WebContent processes to multiple web views until an implementation-defined process limit is reached, but the app cannot require a specific process count or memory allocation. Multiple `WKProcessPool` instances no longer force separate processes. A child WebView would also duplicate ChatGPT JavaScript, layout, network traffic, and memory. Its DOM cannot be donated to the visible WebView.

A future parallel-loader experiment would require instrumentation and strict limits. It should begin with one optional child, prove that a distinct WebContent process is actually used, measure total memory and termination frequency, and demonstrate a transferable result before more children are considered.

## Durable large-conversation path

Live-page optimization cannot guarantee that an arbitrarily large provider page remains resident. Future Issue #48 tracks a separate resumable Chat Mirror extractor and native lazy conversation viewer. That feature will persist conversation chunks locally and display them independently of the live ChatGPT DOM.

## Acceptance criteria

This experiment is successful when:

1. Visible chat content can be scrolled while ChatGPT still reports loading.
2. The user can select access and render bucket counts without rebuilding the app.
3. Advanced controls can be changed independently and persist through restart.
4. Presets produce reproducible groups of settings.
5. Access recovery does not destroy or override render-window settings.
6. Horizontal page movement can remain locked when selected.
7. The default Balanced preset preserves the known build 83 behavior.
8. Compatibility mode provides a meaningful no-intervention baseline.
9. Diagnostics distinguish target loss, page navigation, memory warnings, and WebContent process termination where instrumentation is available.
10. Device tests identify which controls improve usable access without silently losing required conversation content.
