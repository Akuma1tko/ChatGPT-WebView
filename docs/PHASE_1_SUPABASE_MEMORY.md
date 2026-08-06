# Phase 1: Supabase Memory Foundation

## Objective

Create the first version of a durable memory layer so future app sessions can continue project work without relying on a single overloaded chat session.

Phase 1 does not replace ChatGPT yet. It creates the database, Edge Function API shape, and app side client boundary needed for a future API based GPT app.

## User problem

Current workflow:

```text
Long chat session grows heavy
  -> performance degrades
  -> new chat has no context
  -> files and decisions must be reuploaded or restated
```

Target workflow:

```text
User starts or resumes a project
  -> app searches Supabase memory
  -> app loads only relevant summaries and facts
  -> GPT continues from compact context
```

## Phase 1 deliverables

### Repository deliverables

- `docs/PROJECT_GOALS.md`
- `docs/PHASE_1_SUPABASE_MEMORY.md`
- `supabase/migrations/20260628160000_create_memory_schema.sql`
- `supabase/functions/memory/index.ts`
- `supabase/functions/memory/deno.json`
- Swift memory client stubs under `AppMemory/`

### Supabase deliverables

- Memory schema tables
- Row Level Security enabled
- Owner based policies
- Edge Function API skeleton
- Security advisors reviewed after migration

## Memory objects

### projects

Top level workspace, such as `ChatGPT-WebView`, `SAM.gov Search`, or `IBCS ConOps`.

### sessions

A logical chat or work session. This can represent a ChatGPT conversation, app chat, repo work session, or document analysis session.

### messages

Optional raw message storage for app controlled chats. For official ChatGPT WebView sessions, this should stay empty unless the user explicitly exports and imports content.

### session_summaries

Compact summaries of what happened in a session.

These are more important than full raw chat transcripts because they keep future context small.

### memory_items

Atomic reusable facts, decisions, and notes.

Examples:

- `Trusted IPA must come from Build Generated iOS 16 IPA workflow.`
- `Do not trust upstream release IPA unless separately inspected.`
- `Supabase service role key must not be embedded in IPA.`

### artifacts

Links or references to outputs, such as IPA artifacts, GitHub PRs, Excel trackers, generated PDFs, logs, or screenshots.

### files

Metadata and summaries for files analyzed by the app.

### tool_events

Audit trail of tool actions like `search_memory`, `save_memory`, or `summarize_session`.

## Phase 1 API shape

The Edge Function starts with one endpoint, `/memory`, and dispatches by `action`.

Initial actions:

```json
{ "action": "create_project", "name": "ChatGPT-WebView" }
{ "action": "list_projects" }
{ "action": "save_memory", "project_id": "...", "title": "...", "content": "...", "tags": ["repo", "ipa"] }
{ "action": "search_memory", "project_id": "...", "query": "ipa trust chain" }
{ "action": "save_session_summary", "project_id": "...", "session_id": "...", "summary": "..." }
{ "action": "get_project_context", "project_id": "..." }
```

## Security model

- Supabase Auth identifies the user.
- Database rows are owned by `auth.uid()`.
- RLS blocks cross user access.
- Edge Function requires JWT.
- Service role keys stay server side only.
- The iOS app receives only publishable Supabase config.

## Non goals for Phase 1

- No full ChatGPT replacement yet.
- No JavaScript injection into `chatgpt.com`.
- No scraping existing ChatGPT web sessions.
- No Apple signing secrets.
- No service role key inside the IPA.

## Success criteria

Phase 1 is complete when:

1. The database schema exists in Supabase.
2. RLS policies are active.
3. The Edge Function can create/search/list memory using an authenticated user.
4. The repo documents the project goals and memory architecture.
5. The iOS app has a clean client boundary ready for Phase 2.
