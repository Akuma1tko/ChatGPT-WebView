# Context Pack Guide

## Purpose

The context pack is a temporary repo memory bridge.

It follows the useful pattern from tools like `gpt-project-context`: gather important project files, format them into one pasteable block, and use that block to start or restart a ChatGPT thread with current repository context.

This does not replace the real memory architecture.

The real target remains:

```text
ChatGPT
  -> ChatGPT App / MCP connector
  -> memory backend tools
  -> Supabase memory database
```

The context pack is only a durable fallback while the MCP connector is being built.

## What it solves

The context pack solves this short term problem:

```text
New chat starts
  -> previous discussion is not loaded
  -> paste one generated context pack
  -> ChatGPT immediately has repo direction, important docs, schema, Swift files, and next steps
```

## What it does not solve

The context pack does not:

- save conversation memory automatically
- let ChatGPT call Supabase memory tools
- replace user approval flows
- replace the future MCP connector
- keep itself updated unless the script is rerun

## Files included

The generator intentionally uses a fixed allowlist instead of copying the whole repo.

The default pack includes:

- front README
- saved memory direction context
- project goals
- Phase 1 and Phase 2A memory docs
- Copy Context workflow
- Phase 4B multi cloud file context
- Supabase setup and auth docs
- project configuration
- Supabase memory schema migration
- Supabase memory Edge Function
- BYO setup script
- Swift memory models and client
- app model and tab layout
- ChatGPT WebView stop/refresh code
- Memory dashboard UI

## Generate with Bash

From the repo root:

```sh
scripts/build-context-pack.sh
```

Custom output path:

```sh
scripts/build-context-pack.sh docs/PROJECT_CONTEXT_PACK.md
```

## Generate with PowerShell

From the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-context-pack.ps1
```

Custom output path:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-context-pack.ps1 -OutputPath docs/PROJECT_CONTEXT_PACK.md
```

## Default output

The default generated file is:

```text
docs/PROJECT_CONTEXT_PACK.md
```

This file is generated and may become large. It should be regenerated when the repo direction or important implementation files change.

## Recommended ChatGPT startup flow

1. Run the context pack script.
2. Open `docs/PROJECT_CONTEXT_PACK.md`.
3. Paste it into a new ChatGPT thread.
4. Ask ChatGPT to respond with `OK` and wait for instructions.
5. Continue the project from the current repo state.

Example first prompt:

```text
Here is the current ChatGPT-WebView repository context. Read it, respond with OK, and wait for my next instruction.

<paste PROJECT_CONTEXT_PACK.md here>
```

## Token and size warning

The scripts estimate token count using a rough character based calculation.

Warnings:

```text
> 30k estimated tokens: may be too large for some chats
> 100k estimated tokens: trim the included files before pasting
```

The estimate is intentionally simple. It is meant as a practical warning, not an exact tokenizer.

## Relationship to MCP memory

This is a bridge.

The context pack helps ChatGPT understand the repository while we build the real connector.

The future MCP connector should replace this workflow with approved tools:

```text
list_projects
get_project_context
search_memory
propose_context_save
save_context_after_approval
save_session_summary
```

When that connector exists, the context pack can remain as an emergency fallback and onboarding artifact.
