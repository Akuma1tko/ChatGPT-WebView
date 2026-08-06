# ContextPort 2.10.18

ContextPort 2.10.18 combines all product work merged since the published 2.10.3 release. This update focuses on large ChatGPT Work conversations, session recovery, native downloads, image saving, configurable performance controls, and recovery from failed ChatGPT JavaScript assets.

## Highlights

### Large ChatGPT Work conversations

- Added a bounded Work session watchdog that offers a session preserving reload when ChatGPT remains noninteractive.
- Improved startup positioning so long conversations can reach the newest available response while ChatGPT continues loading.
- Added **Progressive Chat Access** with 1 through 12 access buckets and configurable recovery passes.
- Added render buckets for testing visible conversation windows from 5 through 100 messages.
- Restored responsive streaming performance by removing the indefinite whole document observer that reacted to every text update.
- Preserved **Follow Latest** using a cached conversation scroll target and lower frequency checks.
- Added a conversation scroll guard so ChatGPT Settings, the sidebar, menus, profile panels, drawers, and dialogs remain under manual user control instead of being forced to their bottom.
- Preserved the manual **Scroll to Bottom** action for the conversation.

### Complete optimization test matrix

ContextPort Settings now includes direct controls for:

- Compatibility, Balanced, Aggressive, Extreme, and Diagnostic presets
- recovery timing, access buckets, passes, and foreground or memory warning behavior
- native WebView scrolling and indicators
- Follow Latest timing and handoff thresholds
- scroll target detection
- conversation rendering and media pressure experiments
- optional diagnostics
- **Reset All Optimization Settings**, which restores the actual factory configuration

The controls remain available inside unsigned builds and can be tested independently instead of relying on one hardcoded memory configuration.

### JavaScript asset recovery

- Detects failed ChatGPT CDN JavaScript modules and module preloads.
- Presents a **Repair** action only when a failed asset leaves the ChatGPT page stalled.
- Retries the failed asset, warms the WebKit cache, and reloads the same conversation once without clearing the login or ContextPort Memory.
- Adds bounded Developer Sources retries for transient timeouts using 30, 45, and 60 second attempts.
- HTTP errors, invalid source text, oversized responses, and cancellation still fail immediately rather than looping.

### Session restore and startup control

- Checkpoints the exact authenticated provider and profile URL before iOS suspension.
- Uses the lightweight checkpoint during WebView reconstruction so the most recent conversation wins over an older browser state snapshot.
- Adds **Settings → Startup → Restore Last Chat**.
- Turning Restore Last Chat off clears saved conversation URLs while preserving provider sign ins, cookies, local storage, saved profiles, and Memory.
- Guest sessions remain temporary and are not checkpointed.

### Downloads and image saving

- PowerPoint attachments now download through the native WebKit download path instead of opening only in the embedded viewer.
- Completed PowerPoint downloads open the iOS document export picker.
- Added the required add only Photos privacy description so **Save Image to Photos** prompts for permission instead of terminating ContextPort.
- No custom image downloader or broad page interception was added to the Photos fix.

### Interface and privacy

- Replaced separate Stop and Refresh controls with one compact menu containing Refresh, Stop, and Scroll to Bottom.
- Keeps Save Context, Paste Context, or Attach Files directly visible in a narrow centered control.
- Added **Hide Logged In User Name** for screen recording. The AI selector displays **Current User** without modifying the stored account name or session.
- Added **Buy the Developer a Coffee** at the bottom of Settings.

### Repository and release maintenance

- Added a repository controlled Release Assistant that creates or updates draft releases using the repository GitHub token.
- Hardened draft detection and records each completed release operation in a repository status file.
- Updated the README for the current Work scrolling, PowerPoint, Photos, Memory, and Developer Mode behavior.
- Documented a future server independent community discussion architecture. No community runtime is included in this build.

## Important installation note

After installing the new IPA, fully close and relaunch ContextPort. ChatGPT WebView user scripts are installed when a new WebView process starts, so an already running process can continue using the previous scrolling behavior until the app is relaunched.

## Version

- Version: 2.10.18
- Build: 98
- Minimum iOS version: iOS 16
- Release target: `c2e7a09d7d7c7419809fc38403656635baf40835`

## Validation

- The source controlled iOS 16 IPA workflow passed for the final PR #49 build 98 head before merge.
- The Settings and sidebar scroll correction was physically confirmed after fully relaunching the installed IPA.
- The release target includes 83 commits after the published 2.10.3 tag.
- Rejected image save experiments from PRs #35 and #36 are not included.

## Merged work since 2.10.3

- PR #33: stalled ChatGPT Work session recovery
- PR #34: newest message positioning and native PowerPoint downloads
- PR #37: Save Image to Photos privacy crash correction
- PR #38: README update for the accepted feature baseline
- PR #39: compact chat controls and manual Scroll to Bottom
- PR #40: active response Follow Latest behavior
- PR #41: last conversation checkpoint before suspension
- PR #42: developer support link and future community design
- PR #43: restoration of fast Work scrolling
- PR #44: Restore Last Chat preference
- PR #45 and #46: repository controlled draft release support
- PR #47: progressive access, optimization matrix, screen recording privacy, JavaScript repair, and Developer Sources timeout recovery
- PR #49: protection against automatic scrolling inside ChatGPT Settings, sidebar, menus, and dialogs

Full comparison:

https://github.com/DeerSpotter/ContextPort/compare/2.10.3...c2e7a09d7d7c7419809fc38403656635baf40835

## Installation

The draft release does not publish automatically. Add the preferred unsigned IPA and any supporting artifacts, review the notes, then publish when ready. Existing signing and sideloading requirements remain unchanged.
