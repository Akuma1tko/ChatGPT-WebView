# Phase 5: Virtual MCP Memory

## Goal

Prototype the future ChatGPT memory connector inside the iOS app before building the real HTTP MCP server.

The idea is to virtualize the server boundary in the app:

```text
App UI
  -> virtual MCP tool contract
  -> app tool handler
  -> Supabase memory client
  -> Supabase memory Edge Function
```

Later, the same tool names and schemas can move behind a real MCP transport:

```text
ChatGPT
  -> real MCP server over HTTPS
  -> same tool contract
  -> Supabase memory backend
```

## Product rule

This is still not the final memory system.

The real memory system remains:

```text
ChatGPT
  -> ChatGPT App / MCP connector
  -> approved memory tools
  -> Supabase memory database
```

The virtual MCP layer exists to prove the tool contract, approval flow, and Supabase write path before exposing a real server endpoint.

## Why this helps

Building the virtual layer first lets us validate:

- tool names
- input fields
- output fields
- approval requirements
- Supabase writes
- app UX around memory proposals
- searchability of saved memory afterward

It avoids building a public connector before knowing whether the memory proposal shape actually feels useful in the app.

## First virtual tool

```text
save_context_after_approval
```

This tool represents the future approved write action.

It is intentionally named like the real MCP tool should be named later.

## First tool input contract

```json
{
  "project_id": "optional uuid; app can use the selected project",
  "title": "short memory title",
  "summary": "compact memory summary",
  "decisions": ["decision 1", "decision 2"],
  "open_tasks": ["task 1", "task 2"],
  "files_discussed": ["file or artifact 1"],
  "next_steps": ["step 1", "step 2"],
  "tags": ["memory", "mcp"],
  "importance": 1
}
```

`importance` is clamped to the range `1...5`.

## First tool output contract

```json
{
  "saved": true,
  "project_id": "uuid",
  "memory_item_id": "uuid",
  "session_summary_id": "uuid",
  "tool_name": "save_context_after_approval",
  "message": "Virtual MCP save_context_after_approval saved approved context."
}
```

## Current implementation

The app now includes:

```text
ChatGPTWebView/VirtualMCP/VirtualMCPModels.swift
ChatGPTWebView/VirtualMCP/VirtualMCPMemoryFormatter.swift
```

`VirtualMCPModels.swift` defines:

- `VirtualMCPToolDescriptor`
- `VirtualMCPToolRegistry`
- `VirtualMCPSaveContextProposal`
- `VirtualMCPSaveContextResult`

`VirtualMCPMemoryFormatter.swift` converts the proposal into a compact memory item body and normalized tags.

`AppModel` exposes:

```text
runVirtualSaveContextAfterApproval(...)
```

That method:

1. validates the selected project
2. validates title and summary
3. formats a memory item
4. saves the item through `SupabaseMemoryClient.saveMemory`
5. saves a session summary through `SupabaseMemoryClient.saveSessionSummary`
6. stores the last virtual MCP result for the UI

The Memory tab includes a `Virtual MCP Save` card that works like an approval surface.

## Approval behavior

The virtual tool requires user approval.

In the current app, the approval action is the button:

```text
Approve Virtual Save
```

A real MCP connector should preserve the same approval intent. Memory write tools should not silently save without user review.

## What this does not do yet

This phase does not yet:

- expose an HTTP MCP endpoint
- connect directly from ChatGPT
- handle marketplace/App Directory submission
- implement OAuth for a public connector
- provide a custom ChatGPT widget
- support every future memory tool

## Next tools

After `save_context_after_approval` is proven, add virtual versions of:

```text
list_projects
get_project_context
search_memory
propose_context_save
save_session_summary
```

## Migration path to real MCP server

The next implementation should create:

```text
mcp/memory-server/
  package.json
  src/index.ts
  README.md
  .env.example
```

That real server should reuse the virtual tool contract and call the same Supabase Edge Function, but through a server-side adapter suitable for ChatGPT Apps / MCP.

## Acceptance criteria

- User can select a memory project.
- User can review a structured memory proposal in the app.
- User can tap `Approve Virtual Save`.
- App saves both a memory item and a session summary.
- UI shows the saved memory item id and session summary id.
- The saved result can be found through Memory search.
- Same tool name and schema can be reused by a future real MCP server.
