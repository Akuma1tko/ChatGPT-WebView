# Onboarding Options

## Problem

Pure bring your own Supabase setup is secure, but it is too much work for most users.

A normal user should not have to create OAuth apps, copy callback URLs, deploy SQL migrations, deploy Edge Functions, and paste keys before they can try the app.

Advanced users should still get an easier path than fully manual setup.

## Recommended product model

Use a hybrid onboarding model.

## 1. Hosted mode, default

Hosted mode is the normal public app experience.

```text
User opens app
  -> taps Continue with GitHub, Google, Apple, or Microsoft
  -> app uses the maintainer hosted Supabase memory backend
  -> Supabase Auth identifies the user
  -> RLS scopes rows to that user
  -> memory works immediately
```

The iOS app may include:

- hosted Supabase project URL
- hosted Supabase publishable key

The iOS app must never include:

- Supabase secret key
- service role key
- database password
- OAuth provider client secrets

This does not make all maintainer databases available. It only exposes the public client entry point for one purpose built hosted memory project. Access control must be enforced with Supabase Auth, RLS, and JWT protected Edge Functions.

Before hosted mode is production ready, add:

- account delete
- data export
- data delete
- privacy notice
- abuse/rate limits
- logs review

## 2. Assisted BYO Supabase mode, advanced

BYO mode remains available for advanced users who want their own isolated backend, but it should be assisted instead of fully manual.

```text
User opens app
  -> chooses Advanced: Use My Own Supabase
  -> chooses one assisted setup path
  -> app verifies the project URL, publishable key, schema, and memory function
  -> app stores memory only in that user's Supabase project
```

This mode is better for private internal use, self hosting, or users who do not want data in the hosted backend.

### Assisted setup paths

#### A. ChatGPT connector assisted setup

Best for users already using this repo with ChatGPT and the Supabase connector.

```text
User connects Supabase to ChatGPT
  -> ChatGPT applies migrations
  -> ChatGPT deploys Edge Function
  -> ChatGPT gives the user the project URL and publishable key
  -> user pastes those into the app or imports a config QR/deep link
```

This can set up database tables and Edge Functions, but OAuth provider secrets still belong in Supabase or provider dashboards, not in the iOS app.

#### B. One command CLI setup

Best for technical users on a computer.

```text
npx / shell script
  -> asks for Supabase project ref
  -> runs migrations
  -> deploys memory function
  -> prints project URL and publishable key instructions
```

The CLI can reduce setup to one guided terminal command.

#### C. Config import

Best for mobile users.

```text
Generated setup link or QR
  -> chatgptwebview://setup?url=<project-url>&key=<publishable-key>
  -> app opens and saves config
```

The setup link must include only public client config: project URL and publishable key. It must never include a secret key, service role key, OAuth client secret, or database password.

#### D. In app setup browser

Best for mobile users who need to configure GitHub or Supabase without losing their place in the app.

```text
Setup screen
  -> Open Supabase Dashboard
  -> Open GitHub OAuth Apps
  -> copy app callback URL
  -> copy provider callback URL
  -> Done returns to the setup screen
```

This is not true iOS Picture in Picture. It uses an in app Safari sheet so the user can finish setup without fully switching context away from the app.

#### E. Diagnostics screen

The app should test the advanced setup and explain what is missing:

- project URL reachable
- publishable key valid
- user can log in
- `memory` Edge Function exists
- memory tables exist
- RLS is enabled
- callback URL is configured
- GitHub/Google/Apple/Microsoft provider is enabled if selected

## First launch UX target

```text
Choose memory backend

[Continue with Hosted Memory]
Best for most users. Sign in and start using memory.

[Advanced: Use My Own Supabase]
Private backend. Guided setup, config import, or manual setup.
```

## Implementation tasks

- Add backend mode selector: Hosted / BYO.
- Keep BYO setup screen as advanced mode.
- Add hosted config constants only after a production hosted memory project is ready.
- Add clear warnings that hosted mode stores data in the maintainer hosted Supabase project.
- Add export/delete controls before marking hosted mode production ready.
- Add config import by deep link and QR code.
- Add in app setup browser links for Supabase dashboard, GitHub OAuth Apps, and repo docs.
- Add callback URL copy buttons.
- Add diagnostics for provider not enabled, missing memory function, missing schema, and invalid callback URLs.
- Add one command setup script for advanced desktop users.
- Add ChatGPT connector assisted setup guide.

## Current Phase 2A status

Phase 2A currently implements BYO mode. That was the safer first implementation because it avoids accidentally turning the maintainer's Supabase project into the backend for every installed copy.

The next usability phase should add hosted mode as the default and keep BYO mode as Advanced Setup, but make Advanced Setup assisted through connector setup, CLI setup, config import, in app setup browser, and diagnostics.
