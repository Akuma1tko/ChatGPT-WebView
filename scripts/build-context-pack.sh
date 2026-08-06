#!/usr/bin/env bash
set -euo pipefail

if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT_DIR="$(git rev-parse --show-toplevel)"
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

cd "$ROOT_DIR"

OUTPUT_PATH="${1:-docs/PROJECT_CONTEXT_PACK.md}"
mkdir -p "$(dirname "$OUTPUT_PATH")"

IMPORTANT_FILES=(
  "README.md"
  "docs/SAVED_CONTEXT_MEMORY_DIRECTION.md"
  "docs/PROJECT_GOALS.md"
  "docs/PHASE_1_SUPABASE_MEMORY.md"
  "docs/PHASE_1_DEPLOYMENT_STATUS.md"
  "docs/PHASE_2A_MEMORY_UI.md"
  "docs/COPY_CONTEXT_FOR_CHATGPT.md"
  "docs/PHASE_4B_MULTI_CLOUD_FILE_CONTEXT.md"
  "docs/PHASE_5_VIRTUAL_MCP_MEMORY.md"
  "docs/AUTH_LOGIN_REDIRECT_SETUP.md"
  "docs/CONNECTOR_ASSISTED_SETUP.md"
  "project.yml"
  "supabase/migrations/20260628160000_create_memory_schema.sql"
  "supabase/functions/memory/index.ts"
  "scripts/setup-byo-supabase-memory.sh"
  "AppMemory/MemoryModels.swift"
  "AppMemory/SupabaseMemoryClient.swift"
  "ChatGPTWebView/App/AppModel.swift"
  "ChatGPTWebView/App/RootView.swift"
  "ChatGPTWebView/VirtualMCP/VirtualMCPModels.swift"
  "ChatGPTWebView/VirtualMCP/VirtualMCPMemoryFormatter.swift"
  "ChatGPTWebView/Web/ChatGPTTabView.swift"
  "ChatGPTWebView/Web/ChatGPTWebViewStore.swift"
  "ChatGPTWebView/Web/SecureChatGPTWebView.swift"
  "ChatGPTWebView/Memory/MemoryTestView.swift"
)

{
  echo "# ChatGPT-WebView Project Context Pack"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Purpose: paste this into ChatGPT when starting a new thread so the project state, product direction, Supabase memory schema, and next steps are available without manually restating the context."
  echo
  echo "Important instruction for ChatGPT: use this as repository context. Do not treat this generated pack as canonical source over the files it contains. If there is conflict, prefer the most specific source file section."
  echo
  echo "---"
  echo
  echo "## Included files"
  echo
  for file in "${IMPORTANT_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      echo "- $file"
    else
      echo "- $file (missing)"
    fi
  done
  echo
} > "$OUTPUT_PATH"

missing_count=0
included_count=0

for file in "${IMPORTANT_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    missing_count=$((missing_count + 1))
    {
      echo
      echo "---"
      echo
      echo "# FILE: $file"
      echo
      echo "Missing from this checkout."
    } >> "$OUTPUT_PATH"
    continue
  fi

  included_count=$((included_count + 1))
  {
    echo
    echo "---"
    echo
    echo "# FILE: $file"
    echo
    cat "$file"
    echo
  } >> "$OUTPUT_PATH"
done

byte_count=$(wc -c < "$OUTPUT_PATH" | tr -d ' ')
estimated_tokens=$(( (byte_count + 3) / 4 ))

echo "Context pack written: $OUTPUT_PATH"
echo "Included files: $included_count"
echo "Missing files: $missing_count"
echo "Approx bytes: $byte_count"
echo "Estimated tokens: $estimated_tokens"

if (( estimated_tokens > 100000 )); then
  echo "CRITICAL: estimated context pack is over 100k tokens. Consider trimming files before pasting."
elif (( estimated_tokens > 30000 )); then
  echo "WARNING: estimated context pack is over 30k tokens. This may be too large for some chats."
fi
