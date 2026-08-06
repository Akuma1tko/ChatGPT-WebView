# Phase 1 Deployment Status

## Target project

Supabase project: `ChatGPT-WebView`

This is the dedicated Supabase project for the ChatGPT memory app work.

## Applied database migrations

The Phase 1 schema was applied in smaller operational migrations:

1. `create_memory_tables`
2. `create_memory_indexes_and_triggers`
3. `enable_memory_rls`
4. `harden_memory_rls_policies`
5. `add_memory_foreign_key_indexes`
6. `optimize_memory_projects_sessions_rls`
7. `optimize_memory_messages_summaries_rls`
8. `optimize_memory_items_artifacts_rls`
9. `optimize_memory_files_rls`
10. `optimize_memory_tool_events_rls`

## Created memory tables

- `memory_projects`
- `memory_sessions`
- `memory_messages`
- `memory_session_summaries`
- `memory_items`
- `memory_artifacts`
- `memory_files`
- `memory_tool_events`

## Edge Function

Function name: `memory`

Status: deployed

JWT verification: enabled

## Advisor status

Security advisor: clean after hardening.

Performance advisor: only unused index informational entries remain. That is expected before the new tables have production traffic.

## Notes

The first migration in this PR records the intended schema. The live deployment was applied in smaller steps because the connector accepted smaller migration blocks more reliably.

The generated text search column was removed from Phase 1 because Postgres rejected the original generated expression as non immutable. Phase 1 uses simple title/content search through the Edge Function. Full text or vector search should be added later as a dedicated Phase 3 migration.
