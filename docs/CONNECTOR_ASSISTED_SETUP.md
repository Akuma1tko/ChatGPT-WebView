# Connector Assisted Supabase Setup

## Goal

Make advanced BYO Supabase setup easier before a user starts the manual provider setup flow.

This path is intended for users who are working with ChatGPT and have the Supabase connector available.

## What the connector can do

The connector can help with:

- confirming the target Supabase project
- applying SQL migrations
- deploying the `memory` Edge Function
- checking Supabase advisors
- verifying that expected memory tables exist
- verifying that the Edge Function exists

## What the connector should not do

The connector should not put secrets in the iOS app.

The app should receive only:

- Supabase project URL
- Supabase publishable key

The app should never receive:

- Supabase secret key
- service role key
- database password
- OAuth provider client secret

## Assisted setup flow

```text
User says: Set up BYO Supabase for this app
  -> confirm target Supabase project
  -> apply supabase/migrations/20260628160000_create_memory_schema.sql
  -> deploy supabase/functions/memory
  -> verify tables and function
  -> tell user the project URL
  -> tell user where to copy the publishable key
  -> generate a setup deep link if the user provides the publishable key
```

## Setup deep link format

```text
chatgptwebview://setup?url=<url-encoded-project-url>&key=<url-encoded-publishable-key>
```

Example shape:

```text
chatgptwebview://setup?url=https%3A%2F%2Fproject-ref.supabase.co&key=sb_publishable_...
```

The deep link imports the config into the app. It does not log the user in and it does not deploy anything.

## Current limitations

OAuth provider setup still requires provider dashboard work unless a future management API flow is added.

For GitHub login, the user must still create a GitHub OAuth App and paste the GitHub Client ID and Client Secret into Supabase Auth Providers. The GitHub Client Secret belongs in Supabase, not in the app.

## In app validation

After import or manual entry, the app diagnostics screen checks:

- local config format
- Supabase Auth settings reachability
- enabled social providers reported by Supabase Auth
- `memory` Edge Function reachability
- whether the `memory` function appears JWT protected before login

The app cannot fully prove table/RLS correctness until the user is logged in and calls the memory function.
