# Project Goals

## Mission

Build a trusted iOS 16 ChatGPT companion app that avoids suspicious WebView behavior and gives the user durable project memory across chat sessions.

The app should reduce the repeated cycle of:

1. Long chat gets heavy.
2. New chat starts with no context.
3. User has to reupload files and restate project history.
4. Progress slows down or prior decisions are lost.

## Core goals

### 1. Trusted build chain

The app must be buildable from source in this repository using GitHub Actions.

Rules:

- Do not depend on unaudited upstream IPA releases.
- Keep generated build artifacts traceable to repository source.
- Prefer unsigned IPA artifacts until the source and signing path are trusted.
- Avoid hidden scripts, opaque binaries, or release-only behavior.

### 2. No risky ChatGPT WebView injection

The first trusted IPA is a clean WebView wrapper. Future Supabase memory features should not rely on JavaScript injection into `chatgpt.com`.

Avoid:

- reading ChatGPT cookies
- intercepting login credentials
- scraping full pages from the WebView
- proxying ChatGPT traffic through unknown servers
- injecting hidden JavaScript into OpenAI pages

### 3. Supabase backed project memory

Supabase should become the external memory layer for projects, sessions, summaries, artifacts, and reusable facts.

The memory layer should let a new chat resume from a compact set of relevant context instead of reloading an entire old conversation.

Initial memory categories:

- project goals
- session summaries
- important decisions
- open tasks
- artifact links
- file analysis notes
- repo/build events
- reusable facts and preferences

### 4. API based GPT app path

The long term app should evolve from a plain WebView wrapper into a native API based chat app.

Target architecture:

```text
iOS SwiftUI app
  -> app backend / Supabase Edge Functions
  -> Supabase Postgres memory store
  -> OpenAI API with tool calls
```

This is the correct path for letting GPT use Supabase data as tools. A WebView alone cannot make the official ChatGPT web runtime use our database.

### 5. Virtual file context layer

A later phase should let users connect cloud storage accounts and experience them as one AI file space.

The file layer should keep large uploads, zips, PDFs, repo archives, spreadsheets, and document bundles outside the GPT sandbox. The backend should route files into user connected storage, process them with workers, and expose them to GPT through scoped context links and narrow tool calls.

This does not replace the native ChatGPT upload button. It belongs in the app upload UI, the future OpenAI API chat tab, or a later ChatGPT App, Action, or MCP style bridge.

### 6. Virtual MCP connector path

The app can prototype the future connector by virtualizing MCP tools inside the app first.

The virtual MCP layer should use the same tool names, input contracts, output contracts, and approval requirements planned for the real ChatGPT App / MCP connector.

Prototype architecture:

```text
Memory tab approval UI
  -> virtual MCP tool contract
  -> AppModel tool handler
  -> SupabaseMemoryClient
  -> Supabase Edge Function
  -> Supabase memory tables
```

Future architecture:

```text
ChatGPT
  -> real MCP server over HTTPS
  -> same tool contract
  -> Supabase memory backend
```

This lets the app prove the memory tool contract before exposing a real server endpoint.

### 7. Secure by default

Security requirements:

- Never put Supabase service role keys inside the IPA.
- Use Supabase Auth and Row Level Security.
- Use Edge Functions for privileged database operations.
- Store only user approved project memory.
- Keep audit logs for tool activity.
- Make deletion/export possible later.
- Keep cloud provider secrets and tokens out of the iOS app.
- Scope context links by user, project, file, tool permission, and expiration.

## Phase roadmap

### Phase 1: Memory schema and API skeleton

- Add Supabase database schema.
- Add Row Level Security policies.
- Add Edge Function skeleton for memory APIs.
- Add Swift client stubs for memory calls.
- Document how new sessions should resume from stored context.

### Phase 2: Native chat shell

- Add SwiftUI chat UI.
- Add OpenAI API integration through a backend controlled tool layer.
- Add memory search and save flows.
- Add project selector and session resume.

### Phase 3: Summaries and retrieval

- Generate compact session summaries.
- Store memories with tags and importance.
- Add semantic search with embeddings.
- Add project level context packs.

### Phase 4: Files and artifacts

- Store file metadata and extracted summaries.
- Link GitHub artifacts, IPA builds, logs, and analysis outputs.
- Add artifact search.

### Phase 4B: Multi cloud file context layer

- Add virtual file records that separate logical files from physical storage objects.
- Add upload routing into user connected cloud storage.
- Add processing jobs for zips, PDFs, Office files, repo archives, and extracted text.
- Add file manifests, searchable chunks, and context links.
- Add GPT tool endpoints for manifest lookup, search, and slice reads.
- Keep this as a later phase until identity, memory, project selection, and backend audit logs are stable.

### Phase 5: Virtual MCP memory

- Add virtual MCP tool descriptors in the app.
- Add the first approval based virtual tool: `save_context_after_approval`.
- Wire the virtual tool through `AppModel` to `SupabaseMemoryClient`.
- Save both a compact memory item and a session summary.
- Add a Memory tab approval card for testing the flow.
- Keep the same tool name and schema ready for a future real MCP server.

### Phase 6: Trust and release hardening

- Add signed build path.
- Add release notes that include source commit, workflow run, and artifact hash.
- Add security review checklist before shipping.
