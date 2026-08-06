# Context Pack UI Guide

## Purpose

The Context Pack UI is an optional local web interface for targeted file selection.

Use it when the fixed context pack is too broad or when you only want to give ChatGPT a focused slice of the repo.

This is still a temporary bridge.

The real memory target remains:

```text
ChatGPT
  -> ChatGPT App / MCP connector
  -> memory backend tools
  -> Supabase memory database
```

## When to use the fixed script

Use the fixed context pack scripts when you want repeatable full project memory:

```sh
scripts/build-context-pack.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-context-pack.ps1
```

Best for:

- starting a new ChatGPT thread
- restoring the whole project direction
- preserving repeatable default context
- avoiding manual file picking

## When to use the UI

Use the UI when you want targeted context:

```text
Working on WebView controls
  -> select ChatGPTTabView.swift
  -> select ChatGPTWebViewStore.swift
  -> select PHASE_2A_MEMORY_UI.md

Working on MCP planning
  -> select SAVED_CONTEXT_MEMORY_DIRECTION.md
  -> select Supabase migration
  -> select Supabase Edge Function
  -> select Phase 4B docs
```

## Start the UI

From the repo root:

```sh
python3 scripts/context-pack-ui.py
```

On Windows:

```powershell
python scripts/context-pack-ui.py
```

Custom port:

```sh
python3 scripts/context-pack-ui.py --port 8766
```

Do not auto open a browser:

```sh
python3 scripts/context-pack-ui.py --no-open
```

## Local only behavior

The UI binds to:

```text
127.0.0.1:8765
```

Keep it local unless there is a deliberate reason to change the host.

The script is meant for local developer use only. It reads local repo files and exposes them to your local browser session.

## File selection behavior

The UI:

- uses Git when available to list tracked and unignored files
- falls back to directory walking if Git is unavailable
- skips common build/output folders
- skips common binary/archive/image files
- preselects important project files
- supports filtering
- supports selecting all visible files
- supports clearing selection

## Output formats

The UI supports two output modes:

### XML CDATA

Recommended for most use because it is safer with Markdown files and code fences.

```xml
<file path="README.md"><![CDATA[
file content
]]></file>
```

### Markdown fences

Easier to read, but can break if file content contains triple backticks.

````markdown
```README.md
file content
```
````

## Save output

The default save path is:

```text
docs/PROJECT_CONTEXT_PACK.md
```

You can change the output path in the UI before pressing Save.

The output path must stay inside the repo.

## Token count

The UI uses `tiktoken` if it is installed. If not, it falls back to a simple character based estimate.

Optional install:

```sh
python3 -m pip install tiktoken
```

The token count is a guide, not a contract.

## Relationship to MCP memory

This UI is not memory.

It is a targeted context packaging bridge while the actual connector is built.

The final memory system should use approved tools like:

```text
list_projects
get_project_context
search_memory
propose_context_save
save_context_after_approval
save_session_summary
```

When the MCP connector exists, the UI can remain useful for onboarding, debugging, and emergency context recovery.
