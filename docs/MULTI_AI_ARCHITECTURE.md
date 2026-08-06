# ContextPort Multi AI Architecture

## Purpose

ContextPort treats the selected AI provider and selected account profile as separate dimensions while keeping one shared device local Memory.

The runtime hierarchy is:

```text
Shared device local Memory
  -> AI Provider
      -> Profile
          -> WebView Session
```

This prevents provider identity from being modeled as a fake user profile and gives ContextPort a stable path for additional web AI providers.

## Initial providers

The initial provider catalog contains:

- ChatGPT
- Claude
- Gemini
- Grok

Each provider defines its own:

- display name and compact SF Symbol
- start URL
- login URL
- allowed in WebView host suffixes
- authenticated content host suffixes
- unauthenticated URL path prefixes

Provider configuration lives in `ChatGPTWebView/App/AIProvider.swift`.

## Provider selection

`AIProviderManager` owns one persisted `activeProviderID`.

The compact profile popup is a combined AI and profile switcher. The top strip selects the provider. The profile rows below it apply only to the currently selected provider.

The bottom tab label and icon reflect the active provider, so ContextPort keeps the lightweight two tab layout:

```text
Active AI | Memory | AI and Profiles | Settings
```

No extra permanent provider tab was added.

## Provider scoped profiles

Profiles are provider scoped.

Every provider has:

- Current User
- Guest
- zero or more saved login profiles

A saved Claude login is not a ChatGPT login. A Gemini Guest session is not a Grok Guest session.

`AIProfileManager` stores profile state per `AIProviderID` while keeping `ChatGPTProfileManager` as a compatibility type alias for existing source references.

Profile persistence is stored in `MultiAIProviderProfileStatesV1`.

### Guest behavior

Guest remains session only.

Selecting Guest does not change the provider's persisted startup profile. On app launch, each provider restores its last persistent profile instead of Guest.

### Saved profile removal

The small `x` remains available only for saved login profiles.

Removal deletes only that provider and profile session. Shared local Memory is not deleted.

## Session identity

The session pool is keyed by both provider and profile:

```text
AIProfileSessionKey(providerID, profileID)
```

Persistent browser storage uses a namespaced profile identifier:

```text
<provider>::<profile>
```

Examples:

```text
chatgpt::primary
claude::primary
gemini::guest
grok::<saved-profile-uuid>
```

This prevents `primary` and `guest` from colliding across providers.

## WebView security boundary

Each `AIProvider` owns its allowed host suffixes.

`SecureChatGPTWebViewCoordinator` is retained as a compatibility class name, but its navigation allowlist is initialized from the active provider configuration.

Only the configured provider and required authentication domains remain inside that provider's WebView. Other normal web links are opened externally using the existing navigation policy.

## Persistent session behavior

Current User continues to use `WKWebsiteDataStore.default()`.

Saved login and Guest profiles continue to use isolated nonpersistent WebKit data stores.

For persistent profiles, the app managed recovery layer stores:

- cookies in the Keychain
- origin scoped localStorage in Application Support
- last authenticated provider content URL
- explicit logout status

The recovery key is provider scoped.

The last URL is accepted only when its host matches the provider's authenticated content hosts. Authentication pages and cross provider URLs cannot become startup restore URLs.

## Grok authentication chain

Grok authentication stays in one provider WebView through the supported authentication chain.

The coordinator recognizes Grok, xAI, Google, X, Apple, Cloudflare, and Grok authentication bridge hosts required by the provider configuration.

Known Grok authentication bridge completion paths include cookie, session, callback, verification, continuation, and token exchange routes. After bridge completion, ContextPort returns the main Grok WebView to the intended Grok URL so the established session can be consumed.

This model was physically validated on iOS with fresh Grok login and session persistence across provider switching and app relaunch.

## Claude authentication

Claude retains a dedicated OAuth child WebView flow.

The Claude session cookie observer detects the established Claude session, closes any tracked auth popup, and returns the main provider WebView to Claude.

## ChatGPT 2.2.2 migration

Existing ChatGPT session storage used bare profile IDs such as:

```text
primary
<saved-profile-uuid>
```

Version 2.3.0 migrates those snapshots on first use to:

```text
chatgpt::primary
chatgpt::<saved-profile-uuid>
```

The migration copies existing Keychain cookie data and browser state only when the new namespaced key does not already exist.

The legacy ChatGPT profile metadata keys are also kept synchronized for downgrade compatibility.

## Shared Memory

Memory remains local, persistent, app wide, and shared across every provider and profile.

Memory entries do not gain profile IDs or Guest state.

Starting a new chat from Memory targets whichever AI provider is active at that moment.

The app level Paste Context and direct in Memory file bridge are shared. Their JavaScript uses generic composer and file input discovery. Provider DOM changes can still require provider specific selector hardening after physical device testing.

Conversation export receives the active provider configuration and labels assistant messages with the provider name instead of hardcoding ChatGPT.

## ContextPort release identity

The installed product name, release update checker, README, and GitHub Actions IPA artifact names use `ContextPort`.

The update checker targets:

```text
DeerSpotter/ContextPort
```

The primary source controlled IPA is packaged as:

```text
ContextPort-source-ios16-unsigned.ipa
```

The independent unsigned IPA workflow packages:

```text
ContextPort-ios16-unsigned.ipa
```

## Compatibility names

Several internal source filenames and types retain `ChatGPT` in their names to preserve the established source layout, migration paths, and compatibility surfaces.

Compatibility surfaces include:

- `ChatGPTProfileManager` type alias
- `ChatGPTTabView` type alias
- `ChatGPTConversationExporter` type alias
- `ChatGPTWebViewStore`
- `SecureChatGPTWebViewCoordinator`
- `ChatGPTWebView.xcodeproj`
- `ChatGPTWebView` Xcode target and scheme
- `com.deerspotter.ChatGPTWebView` bundle identifier
- `chatgptwebview` URL callback scheme

The runtime product is ContextPort even where a legacy internal source or compatibility name remains.

The bundle identifier and callback scheme are intentionally retained so the rebrand remains an upgrade to the existing installed app instead of creating a new application identity.
