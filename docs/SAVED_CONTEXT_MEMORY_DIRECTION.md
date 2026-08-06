# Saved Context: Memory Direction

## Purpose

This document captures the current project context and product decisions for ChatGPT-WebView memory work.

It exists because project memory should not rely on the user manually rewriting context into a separate form. Until a real connector exists, saving the project direction directly in the repo is the safest durable fallback.

## Current product rule

Manual context writing is not the product goal.

A memory system only matters if it reduces user work. If the user has to manually rewrite the active conversation into a memory form, the system is adding friction instead of solving the context problem.

Manual save/search UI may exist, but only as:

- admin tooling
- debug tooling
- fallback tooling
- verification tooling

It should not be presented as the main product purpose.

## Current architecture direction

The preferred product path is:

```text
ChatGPT
  -> ChatGPT App / MCP connector
  -> memory backend tools
  -> Supabase memory database
```

The connector should allow ChatGPT to propose structured memory and ask for user approval before saving.

The iOS app remains useful as the companion/control panel:

```text
iOS app
  -> Supabase setup
  -> auth diagnostics
  -> project selection
  -> memory review/search
  -> WebView controls
  -> install/testing support
```

The iOS WebView should not become the main memory capture mechanism.

## Why the WebView is not enough

A WebView wrapper cannot reliably know the assistant's internal reasoning, the semantic importance of a conversation turn, or when a thread should be saved as structured memory.

The WebView should not depend on fragile page scraping, hidden page manipulation, or manual text rewriting to create memory.

The WebView can still provide practical controls:

- Stop current WebView activity
- Refresh stale or frozen session
- Keep trusted ChatGPT login flow
- Support companion app workflows

## Correct memory behavior

The desired behavior is:

```text
Conversation reaches an important decision
  -> ChatGPT proposes a structured memory item
  -> user approves or edits
  -> connector saves it to Supabase
  -> future chats can retrieve it
```

Example user flow:

```text
User: save context now
ChatGPT: I will save the current project decision as memory. Approve?
User: approve
Connector: save_context_after_approval(...)
Supabase: durable memory row created
```

## First MCP connector tools

The first private MCP connector should expose a small safe tool set:

```text
list_projects
get_project_context
search_memory
propose_context_save
save_context_after_approval
save_session_summary
```

### list_projects

Returns memory projects the authenticated user can access.

### get_project_context

Returns the selected project's high value context:

- pinned rules
- recent session summaries
- important decisions
- open tasks
- files discussed
- next steps

### search_memory

Searches existing memory for relevant prior context.

### propose_context_save

Creates a structured memory proposal without writing yet.

The proposal should include:

- title
- summary
- decisions
- open tasks
- files discussed
- next steps
- importance
- suggested tags

### save_context_after_approval

Writes approved context into Supabase.

This is the actual write tool and should require user approval.

### save_session_summary

Writes a summarized conversation checkpoint for later retrieval.

## Safety and trust rules

- Do not store Supabase service role keys in the iOS app.
- Do not hardcode one developer Supabase project as the backend for all users.
- Use user scoped auth.
- Keep memory writes approval based.
- Make tool writes auditable.
- Keep manual save/search as fallback only.
- Do not treat page scraping as the memory architecture.

## Current repo state

PR #4 currently captures the direction change:

- manual Save Context overlay removed
- Stop and Refresh WebView controls added
- memory dashboard first layout added
- product rule documented that memory must reduce work
- automatic memory direction documented through OpenAI API chat tab or ChatGPT App / MCP connector

## Next implementation phase

Create Phase 5:

```text
Phase 5: ChatGPT Memory MCP Connector
```

Phase 5 should build the private connector first. Public marketplace or Apps Directory submission should wait until auth, privacy, approvals, audit logging, and test prompts are solid.

Recommended sequence:

1. Finish and validate PR #4.
2. Add Phase 5 MCP connector plan.
3. Create a minimal MCP server package.
4. Wire MCP tools to the existing Supabase memory backend.
5. Test privately in developer mode.
6. Add docs for auth and user approval.
7. Only then evaluate public submission.
