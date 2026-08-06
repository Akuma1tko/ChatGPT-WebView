# Copy Context for ChatGPT

## Purpose

This is the first practical bridge between saved Supabase memory and the ChatGPT WebView.

The app does not inject JavaScript into `chatgpt.com`. Instead, the user searches saved memory, copies a formatted context block, and pastes it into the ChatGPT tab.

## Workflow

```text
Open Memory tab
  -> search saved memory
  -> review results
  -> tap Copy Context for ChatGPT
  -> open ChatGPT tab
  -> paste the formatted context into the chat
```

## Output format

The copied text tells ChatGPT:

- this is saved project memory
- it should be treated as previous user supplied context
- it should be used when relevant
- it should not override the user's current instructions

Example shape:

```text
Use the following saved project memory as background context for this conversation. Treat it as user provided context from previous work. Use it when relevant, but do not assume it overrides my current instructions.

Project: ChatGPT-WebView
Memory search query: oauth redirect

Saved memory results:
1. GitHub login redirect fix
Content: Supabase Site URL and Redirect URLs must include chatgptwebview://auth-callback. GitHub OAuth callback stays as Supabase /auth/v1/callback.
Tags: supabase, github, oauth, ios

Please continue from this context and ask if anything is unclear.
```

## Current limitation

This is manual copy/paste. ChatGPT does not automatically call the Supabase memory backend yet.

## Why this comes before API chat or MCP

This option is intentionally simple. It proves the memory format, user experience, and project context structure before adding a more complex automatic bridge.

Future options:

```text
Option B: Build an OpenAI API chat tab
  -> retrieve memory automatically
  -> send memory context with the prompt

Option C: Build a ChatGPT App/Action/MCP style bridge
  -> ChatGPT can call the same Supabase memory backend directly

Option D: Add multi cloud file context links
  -> app uploads large files into user connected cloud storage
  -> backend creates file manifests, chunks, and searchable indexes
  -> GPT receives a small context link instead of the full file
  -> GPT calls backend tools for manifest lookup, search, and slice reads
```

## File context link extension

The future multi cloud file context layer extends this manual bridge.

Instead of pasting extracted file content directly into ChatGPT, the app should paste a small context card like:

```text
File Context: project-archive.zip
File ID: file_123
Scope: read manifest, search, read extracted slices
Available tools:
- get_file_manifest(file_id)
- list_zip_contents(file_id)
- search_file(file_id, query)
- read_file_slice(file_id, path, start, end)
```

This keeps the full file outside the GPT sandbox. GPT only receives the file summary and asks the backend for small relevant pieces when the future tool bridge is available.

See `docs/PHASE_4B_MULTI_CLOUD_FILE_CONTEXT.md` for the full later phase design.
