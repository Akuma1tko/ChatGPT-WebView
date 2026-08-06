# Phase 4B: Multi Cloud File Context Layer

## Goal

Create a virtual file layer where users connect their own cloud storage accounts, upload files through the app, and experience those accounts as one large AI file space.

The user should feel like they are uploading files into the app for GPT to use, but the trusted backend should route, store, index, and process those files outside the GPT sandbox.

This phase is meant to reduce repeated uploads, prevent large archives from exhausting a chat session, and let GPT work with large files through small controlled tool calls.

## Important boundary

The app should not claim it can replace or intercept the official ChatGPT web upload button.

A WebView wrapper cannot secretly redirect native ChatGPT uploads into user cloud storage. This design only works through one of these controlled paths:

1. The app's own upload UI.
2. An OpenAI API based chat tab controlled by this app.
3. A future ChatGPT App, Action, or MCP style bridge that exposes backend file tools.
4. A manual bridge where the app creates a context link and the user pastes it into ChatGPT.

The trusted design is not direct GPT filesystem access. The trusted design is a backend tool layer that lets GPT request safe file operations.

## User experience target

```text
User connects cloud accounts
  -> user sees one AI Cloud Drive
  -> user uploads a zip, PDF, Excel file, repo archive, or document bundle
  -> backend chooses where the object should live
  -> backend processes and indexes the upload
  -> app creates a context link
  -> GPT receives the context link plus available file tools
  -> GPT asks the backend for manifests, search results, slices, and extracted content
```

The user should not need to know whether a file landed in Supabase Storage, Cloudflare R2, S3, Google Drive, OneDrive, Dropbox, Backblaze B2, Wasabi, or another provider.

## Architecture

```text
iOS SwiftUI app
  -> upload UI
  -> user cloud account manager
  -> context link generator

Backend / Edge Functions
  -> upload router
  -> storage provider adapters
  -> file metadata API
  -> context link API
  -> GPT file tool API

Storage providers
  -> Supabase Storage first
  -> later S3 compatible storage
  -> later user connected drive providers

Processing workers
  -> checksum
  -> malware scan
  -> zip manifest
  -> document text extraction
  -> Excel and CSV summary
  -> PDF text extraction and later OCR
  -> chunking and indexing

Database
  -> cloud account records
  -> virtual file records
  -> storage object records
  -> file manifests
  -> processing jobs
  -> context links
  -> searchable chunks
```

## Core concept

The app stores a durable virtual file record. The physical object can live in any supported provider.

```text
virtual_files
  file_123 = project-archive.zip

storage_objects
  file_123 physical copy A = cloudflare-r2://bucket/key
  file_123 physical copy B = optional backup later

file_manifests
  file_123 contents, extracted files, hashes, searchable text, and summaries

context_links
  ctx://file/file_123 scoped access for GPT tools
```

This gives the user one logical file account while the backend handles placement, routing, indexing, and retention.

## Context link design

The context link should point to a manifest and a scoped tool permission set, not just a raw file URL.

Example shape:

```text
ctx://file/file_123
```

Or for manual paste into ChatGPT:

```text
File Context: project-archive.zip
File ID: file_123
Scope: read manifest, search, read extracted slices
Available tools:
- get_file_manifest(file_id)
- list_zip_contents(file_id)
- search_file(file_id, query)
- read_file_slice(file_id, path, start, end)
- extract_zip_member(file_id, path)
- summarize_folder(file_id, folder_path)
```

GPT should receive enough context to know the file exists, but not the full file content. It should call tools when it needs details.

## Tool layer

The future GPT bridge should expose narrow file tools through the app backend.

Initial tool candidates:

```text
get_file_manifest(file_id)
list_zip_contents(file_id)
search_file(file_id, query)
read_file_slice(file_id, internal_path, start_line, end_line)
read_chunk(file_id, chunk_id)
extract_zip_member(file_id, internal_path)
summarize_folder(file_id, folder_path)
get_processing_status(file_id)
```

Later tool candidates:

```text
run_pdf_text_extract(file_id, internal_path)
run_pdf_ocr(file_id, internal_path)
run_excel_sheet_summary(file_id, internal_path)
run_repo_tree_summary(file_id)
compare_files(file_id_a, file_id_b)
export_context_pack(file_id, query)
```

## Zip processing flow

```text
Upload finishes
  -> create virtual file row
  -> calculate SHA256
  -> record physical storage object
  -> scan for unsafe content
  -> list zip contents without full extraction when possible
  -> create manifest
  -> extract supported text formats
  -> chunk searchable content
  -> store file notes and summaries
  -> mark file ready for context links
```

For very large archives, workers should avoid extracting everything at once. The first pass should create the manifest and only extract high value file types or files requested by GPT tools.

## Placement rules

The backend should choose storage location using explicit policy rules.

Possible routing inputs:

- user selected provider priority
- provider quota
- file size
- file type
- expected processing cost
- expected access frequency
- region
- retention setting
- redundancy setting
- provider health

MVP routing should be simple: one configured storage provider. Later routing can become policy based.

## Draft data model

```text
cloud_accounts
- id
- user_id
- provider
- display_name
- auth_status
- quota_total_bytes
- quota_used_bytes
- is_active
- created_at

virtual_files
- id
- user_id
- project_id
- filename
- mime_type
- size_bytes
- sha256
- status
- created_at

storage_objects
- id
- virtual_file_id
- provider
- bucket_or_drive_id
- object_key
- region
- storage_class
- encrypted
- created_at

file_manifests
- id
- virtual_file_id
- manifest_json
- extracted_file_count
- indexed
- created_at

processing_jobs
- id
- virtual_file_id
- job_type
- status
- error
- started_at
- finished_at

context_links
- id
- virtual_file_id
- user_id
- project_id
- scope_json
- expires_at
- revoked_at
- created_at

file_chunks
- id
- virtual_file_id
- internal_path
- chunk_index
- text
- token_estimate
- metadata_json
- created_at
```

## Implementation phases inside Phase 4B

### Phase 4B.1: Single provider virtual file MVP

Use the existing Supabase direction first.

- Add upload UI.
- Store files in one configured storage provider.
- Create `virtual_files`, `storage_objects`, and `processing_jobs` tables.
- Create manifest rows for uploaded files.
- Create manual context links.

### Phase 4B.2: File processing and search

- Add zip manifest generation.
- Add PDF, DOCX, TXT, CSV, XLSX, and repo archive text extraction.
- Add chunk table.
- Add keyword search first.
- Add embeddings later only after the chunk model is stable.

### Phase 4B.3: Backend GPT file tools

- Add authenticated tool endpoints.
- Support manifest lookup, search, and slice reads.
- Add audit logs for every tool call.
- Add strict scope and expiration to context links.

### Phase 4B.4: Multi provider routing

- Add provider adapter interface.
- Add user connected provider records.
- Add routing policy.
- Add quota awareness.
- Add provider health checks.
- Add optional redundancy after the base flow is reliable.

### Phase 4B.5: API chat and MCP bridge

- Let the future OpenAI API chat tab call file tools automatically.
- Later expose the same tool layer through a ChatGPT App, Action, or MCP bridge.
- Keep the manual context link flow as the fallback.

## Security requirements

- Never store provider secret keys in the iOS app.
- Use OAuth or provider scoped tokens through backend controlled flows.
- Encrypt provider tokens server side.
- Use Row Level Security for all file metadata.
- Scope context links by user, project, file, tool permissions, and expiration.
- Keep audit logs for upload, processing, read, extract, and search actions.
- Add revocation for every context link.
- Add deletion and export paths before calling this production ready.
- Scan uploaded archives before automatic extraction.
- Avoid blindly extracting zip files into shared paths.
- Prevent path traversal inside archives.

## What this phase does not solve by itself

- It does not make ChatGPT web automatically read cloud files.
- It does not intercept the native ChatGPT upload button.
- It does not remove the need for GPT tool calls.
- It does not guarantee unlimited processing. Workers still need quotas and limits.
- It does not replace the current Supabase memory MVP.

## Acceptance criteria

Phase 4B is successful when:

- a user can upload a large zip through the app without putting the zip into GPT sandbox storage
- the app records a virtual file and physical storage object
- the backend creates a manifest and processing status
- the app can create a scoped context link
- GPT can use tool calls to search and read only the relevant slices
- the user can revoke the context link
- the user can delete the file metadata and storage object

## Reason for later phase placement

This belongs after the current memory and context copy phases because it depends on:

- user identity
- project records
- memory project selection
- backend controlled APIs
- storage security rules
- audit logging
- a future API chat or tool bridge

The current MVP should stay focused on Supabase memory and manual context transfer. Multi cloud file context should be planned now, but implemented after the memory foundation is stable.
