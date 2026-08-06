# Auth Login and Redirect Setup

## Purpose

This document records the Supabase and GitHub OAuth setup details learned while getting GitHub login working in the iOS app.

The main lesson:

```text
GitHub OAuth App callback URL is not the same thing as the app redirect URL.
```

## Project used during setup

```text
Supabase project ref:
skejcbgrzlzgyjdjglrk
```

```text
Supabase project URL:
https://skejcbgrzlzgyjdjglrk.supabase.co
```

## Supabase dashboard links

### Auth Providers

Use this page first to enable GitHub, Google, Apple, Microsoft, email, or other auth providers.

```text
https://supabase.com/dashboard/project/skejcbgrzlzgyjdjglrk/auth/providers
```

This is where GitHub login must be enabled and where the GitHub Client ID and GitHub Client Secret are pasted.

### URL Configuration

Use this page to control where Supabase sends the user after login.

```text
https://supabase.com/dashboard/project/skejcbgrzlzgyjdjglrk/auth/url-configuration
```

This is where the app deep link redirect must be added.

## App callback URL

The iOS app callback is:

```text
chatgptwebview://auth-callback
```

Add it to Supabase Authentication URL Configuration.

For this app, it is acceptable to use this as the Site URL during mobile testing:

```text
chatgptwebview://auth-callback
```

Also add it under Redirect URLs:

```text
chatgptwebview://auth-callback
```

## GitHub OAuth App callback URL

The GitHub OAuth App callback URL must point to Supabase, not directly to the iOS app.

For this project, use:

```text
https://skejcbgrzlzgyjdjglrk.supabase.co/auth/v1/callback
```

Generic form:

```text
https://<project-ref>.supabase.co/auth/v1/callback
```

## Correct redirect chain

```text
User taps GitHub login in app
  -> app opens Supabase /auth/v1/authorize?provider=github&redirect_to=chatgptwebview://auth-callback
  -> Supabase redirects to GitHub
  -> GitHub redirects back to Supabase /auth/v1/callback
  -> Supabase creates the user session
  -> Supabase redirects back to chatgptwebview://auth-callback
  -> iOS app receives the session callback
```

## Localhost failure

If the app opens a page that says `localhost` and Safari cannot connect, GitHub login probably worked, but Supabase redirected to the default Site URL instead of the app callback.

This usually means Supabase URL Configuration still has:

```text
http://localhost:3000
```

Fix:

1. Open URL Configuration.
2. Set Site URL to:

```text
chatgptwebview://auth-callback
```

3. Add Redirect URL:

```text
chatgptwebview://auth-callback
```

4. Keep the GitHub OAuth App callback as:

```text
https://skejcbgrzlzgyjdjglrk.supabase.co/auth/v1/callback
```

## What not to paste into the app

The app should only receive:

- Supabase project URL
- Supabase publishable key

Never paste these into the app:

- Supabase secret key
- service role key
- database password
- GitHub OAuth Client Secret
- Google OAuth Client Secret
- Apple private key or client secret
- Microsoft/Azure Client Secret

Provider secrets belong in Supabase Auth Provider settings or the provider dashboard, not in the iOS app.

## Official references

Supabase redirect URL documentation:

```text
https://supabase.com/docs/guides/auth/redirect-urls
```

Supabase GitHub login documentation:

```text
https://supabase.com/docs/guides/auth/social-login/auth-github
```

GitHub OAuth Apps page:

```text
https://github.com/settings/developers
```

Supabase dashboard:

```text
https://supabase.com/dashboard
```

## Notes from working setup

- The GitHub provider was initially not enabled, causing provider errors.
- Enabling GitHub under Supabase Auth Providers fixed the provider issue.
- The OAuth flow then reached Supabase successfully but redirected to localhost.
- Updating Supabase URL Configuration to use `chatgptwebview://auth-callback` fixed the return path.
- After the redirect fix, the app logged in successfully and reached the Memory Test screen.
