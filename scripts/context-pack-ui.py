#!/usr/bin/env python3
"""Local context pack UI for ChatGPT-WebView.

This is a temporary repo memory bridge while the real ChatGPT App / MCP
connector is being built. It starts a localhost-only web UI that lets a
user select targeted repo files, generate a pasteable context pack, copy it,
and optionally save it to docs/PROJECT_CONTEXT_PACK.md.
"""

from __future__ import annotations

import argparse
import html
import json
import mimetypes
import os
import subprocess
import sys
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from urllib.parse import parse_qs, urlparse

DEFAULT_OUTPUT_PATH = "docs/PROJECT_CONTEXT_PACK.md"

IMPORTANT_FILES = [
    "README.md",
    "docs/SAVED_CONTEXT_MEMORY_DIRECTION.md",
    "docs/PROJECT_GOALS.md",
    "docs/PHASE_1_SUPABASE_MEMORY.md",
    "docs/PHASE_1_DEPLOYMENT_STATUS.md",
    "docs/PHASE_2A_MEMORY_UI.md",
    "docs/COPY_CONTEXT_FOR_CHATGPT.md",
    "docs/PHASE_4B_MULTI_CLOUD_FILE_CONTEXT.md",
    "docs/AUTH_LOGIN_REDIRECT_SETUP.md",
    "docs/CONNECTOR_ASSISTED_SETUP.md",
    "project.yml",
    "supabase/migrations/20260628160000_create_memory_schema.sql",
    "supabase/functions/memory/index.ts",
    "scripts/setup-byo-supabase-memory.sh",
    "scripts/build-context-pack.sh",
    "scripts/build-context-pack.ps1",
    "docs/CONTEXT_PACK_GUIDE.md",
    "AppMemory/MemoryModels.swift",
    "AppMemory/SupabaseMemoryClient.swift",
    "ChatGPTWebView/App/AppModel.swift",
    "ChatGPTWebView/App/RootView.swift",
    "ChatGPTWebView/Web/ChatGPTTabView.swift",
    "ChatGPTWebView/Web/ChatGPTWebViewStore.swift",
    "ChatGPTWebView/Web/SecureChatGPTWebView.swift",
    "ChatGPTWebView/Memory/MemoryTestView.swift",
]

SKIP_DIRS = {
    ".git",
    ".build",
    ".swiftpm",
    "DerivedData",
    "build",
    "dist",
    "node_modules",
    "Pods",
    "Carthage",
    ".venv",
    "venv",
    "__pycache__",
}

SKIP_SUFFIXES = {
    ".ipa",
    ".app",
    ".zip",
    ".xcarchive",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".pdf",
    ".sqlite",
    ".db",
    ".DS_Store",
}

TEXT_SUFFIXES = {
    ".md",
    ".txt",
    ".swift",
    ".ts",
    ".tsx",
    ".js",
    ".jsx",
    ".json",
    ".yml",
    ".yaml",
    ".sql",
    ".sh",
    ".ps1",
    ".py",
    ".toml",
    ".plist",
    ".html",
    ".css",
    ".xml",
}

INDEX_HTML = r"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ChatGPT-WebView Context Pack UI</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0f1117;
      --panel: #171a22;
      --panel2: #202431;
      --text: #f4f6fb;
      --muted: #aab0c0;
      --border: #303646;
      --accent: #74b7ff;
      --good: #7bd88f;
      --warn: #ffd166;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      height: 100vh;
      overflow: hidden;
    }
    .app {
      display: grid;
      grid-template-columns: minmax(320px, 38vw) 1fr;
      gap: 14px;
      padding: 14px;
      height: 100vh;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 14px;
      overflow: hidden;
      min-height: 0;
    }
    .left, .right { display: flex; flex-direction: column; }
    .header {
      padding: 12px 14px;
      border-bottom: 1px solid var(--border);
      background: var(--panel2);
    }
    h1 { font-size: 16px; margin: 0 0 4px; }
    p { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.35; }
    .controls {
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
    }
    button, select, input[type="text"] {
      background: var(--panel2);
      color: var(--text);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 8px 10px;
      font-size: 13px;
    }
    button { cursor: pointer; }
    button.primary { border-color: var(--accent); }
    button.good { border-color: var(--good); }
    input[type="text"] { width: 100%; }
    .file-list {
      overflow: auto;
      padding: 10px 14px 16px;
      flex: 1;
      min-height: 0;
    }
    .file-row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 5px 0;
      border-bottom: 1px solid rgba(255,255,255,0.035);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 12px;
      color: var(--muted);
    }
    .file-row.important { color: var(--text); }
    .file-row input { flex: 0 0 auto; }
    .output-toolbar {
      display: grid;
      grid-template-columns: 1fr auto auto auto;
      gap: 8px;
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
      align-items: center;
    }
    textarea {
      flex: 1;
      width: 100%;
      min-height: 0;
      border: 0;
      padding: 12px;
      background: #0b0d12;
      color: var(--text);
      resize: none;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 12px;
      line-height: 1.4;
      outline: none;
    }
    .status {
      color: var(--muted);
      font-size: 12px;
      white-space: nowrap;
    }
    .status.warn { color: var(--warn); }
    .status.good { color: var(--good); }
    label.small {
      font-size: 12px;
      color: var(--muted);
      display: inline-flex;
      gap: 6px;
      align-items: center;
    }
    @media (max-width: 900px) {
      .app { grid-template-columns: 1fr; grid-template-rows: 45vh 1fr; }
      .output-toolbar { grid-template-columns: 1fr 1fr; }
    }
  </style>
</head>
<body>
  <div class="app">
    <section class="panel left">
      <div class="header">
        <h1>Context Pack UI</h1>
        <p>Temporary repo memory bridge. Select targeted files, generate a pasteable context block, and use it until the MCP connector is ready.</p>
      </div>
      <div class="controls">
        <button onclick="selectImportant()">Important defaults</button>
        <button onclick="selectAllVisible()">Select visible</button>
        <button onclick="clearSelection()">Clear</button>
        <label class="small"><input id="importantOnly" type="checkbox" onchange="renderFiles()"> show important only</label>
      </div>
      <div class="controls">
        <input id="filter" type="text" placeholder="Filter files..." oninput="renderFiles()">
      </div>
      <div id="fileList" class="file-list"></div>
    </section>

    <section class="panel right">
      <div class="header">
        <h1>Generated context</h1>
        <p>XML is safer for Markdown and code fences. Markdown is easier to read. Save writes to docs/PROJECT_CONTEXT_PACK.md unless overridden.</p>
      </div>
      <div class="output-toolbar">
        <div class="status" id="status">Loading files...</div>
        <select id="format" onchange="generateContext()">
          <option value="xml" selected>XML CDATA</option>
          <option value="markdown">Markdown fences</option>
        </select>
        <button class="primary" onclick="copyOutput()">Copy</button>
        <button class="good" onclick="saveOutput()">Save</button>
      </div>
      <div class="controls">
        <input id="outputPath" type="text" value="docs/PROJECT_CONTEXT_PACK.md" aria-label="Output path">
      </div>
      <textarea id="output" spellcheck="false"></textarea>
    </section>
  </div>

<script>
let allFiles = [];
let selected = new Set();
let important = new Set();
let tokenMode = 'estimate';

async function loadFiles() {
  const res = await fetch('/api/files');
  const data = await res.json();
  allFiles = data.files || [];
  important = new Set(data.important || []);
  tokenMode = data.token_mode || 'estimate';
  selectImportant();
  renderFiles();
  await generateContext();
}

function visibleFiles() {
  const filter = document.getElementById('filter').value.toLowerCase().trim();
  const importantOnly = document.getElementById('importantOnly').checked;
  return allFiles.filter(file => {
    if (importantOnly && !important.has(file)) return false;
    if (filter && !file.toLowerCase().includes(filter)) return false;
    return true;
  });
}

function renderFiles() {
  const container = document.getElementById('fileList');
  const files = visibleFiles();
  container.innerHTML = files.map(path => {
    const checked = selected.has(path) ? 'checked' : '';
    const klass = important.has(path) ? 'file-row important' : 'file-row';
    const escaped = escapeHtml(path);
    return `<label class="${klass}"><input type="checkbox" data-path="${escaped}" ${checked} onchange="toggleFile(this)"><span>${escaped}</span></label>`;
  }).join('');
}

function toggleFile(box) {
  const path = box.getAttribute('data-path');
  if (box.checked) selected.add(path); else selected.delete(path);
  generateContext();
}

function selectImportant() {
  selected = new Set([...important].filter(path => allFiles.includes(path)));
  renderFiles();
  generateContext();
}

function selectAllVisible() {
  for (const file of visibleFiles()) selected.add(file);
  renderFiles();
  generateContext();
}

function clearSelection() {
  selected.clear();
  renderFiles();
  generateContext();
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}

function cdataSafe(value) {
  return String(value).replaceAll(']]>', ']]]]><![CDATA[>');
}

async function readFile(path) {
  const res = await fetch('/api/file?path=' + encodeURIComponent(path));
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Failed to read ' + path);
  return data.content || '';
}

async function generateContext() {
  const output = document.getElementById('output');
  const format = document.getElementById('format').value;
  const files = [...selected].sort();
  let parts = [];
  parts.push('# ChatGPT-WebView Targeted Context Pack');
  parts.push('');
  parts.push('Generated: ' + new Date().toISOString());
  parts.push('');
  parts.push('Purpose: targeted pasteable repository context while the real ChatGPT App / MCP connector is being built.');
  parts.push('');
  parts.push('Important instruction for ChatGPT: use this as repository context. Prefer specific file sections over this generated header if there is conflict.');
  parts.push('');
  parts.push('---');
  parts.push('');

  for (const path of files) {
    try {
      const content = await readFile(path);
      if (format === 'xml') {
        parts.push(`<file path="${escapeHtml(path)}"><![CDATA[`);
        parts.push(cdataSafe(content));
        parts.push(']]></file>');
        parts.push('');
      } else {
        parts.push('```' + path);
        parts.push(content);
        parts.push('```');
        parts.push('');
      }
    } catch (error) {
      parts.push(`# FILE: ${path}`);
      parts.push('Error reading file: ' + error.message);
      parts.push('');
    }
  }

  const text = parts.join('\n');
  output.value = text;
  await updateTokenCount(text, files.length);
}

async function updateTokenCount(text, fileCount) {
  try {
    const res = await fetch('/api/count', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ text })
    });
    const data = await res.json();
    const status = document.getElementById('status');
    status.className = 'status';
    if (data.tokens > 100000) status.classList.add('warn');
    else if (data.tokens > 30000) status.classList.add('warn');
    else status.classList.add('good');
    status.textContent = `${fileCount} files · ${data.tokens} tokens (${data.mode}) · ${text.length} chars`;
  } catch (error) {
    document.getElementById('status').textContent = `${fileCount} files · token count failed`;
  }
}

async function copyOutput() {
  const text = document.getElementById('output').value;
  await navigator.clipboard.writeText(text);
  const status = document.getElementById('status');
  const old = status.textContent;
  status.textContent = 'Copied to clipboard';
  status.className = 'status good';
  setTimeout(() => { status.textContent = old; }, 1400);
}

async function saveOutput() {
  const path = document.getElementById('outputPath').value || 'docs/PROJECT_CONTEXT_PACK.md';
  const text = document.getElementById('output').value;
  const res = await fetch('/api/save', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ path, content: text })
  });
  const data = await res.json();
  const status = document.getElementById('status');
  if (!res.ok) {
    status.textContent = data.error || 'Save failed';
    status.className = 'status warn';
    return;
  }
  status.textContent = `Saved to ${data.path}`;
  status.className = 'status good';
}

loadFiles();
</script>
</body>
</html>
"""


def find_repo_root(start: Path) -> Path:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=start,
            text=True,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        return Path(result.stdout.strip()).resolve()
    except Exception:
        return start.resolve()


def normalize_repo_path(root: Path, raw_path: str) -> Optional[Path]:
    candidate = (root / raw_path).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return candidate


def is_probably_text(path: Path) -> bool:
    if path.name in {"README", "LICENSE", "NOTICE"}:
        return True
    if path.suffix in TEXT_SUFFIXES:
        return True
    mime, _ = mimetypes.guess_type(path.name)
    return bool(mime and mime.startswith("text/"))


def collect_files(root: Path) -> List[str]:
    try:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd=root,
            text=True,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        files = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    except Exception:
        files = []
        for current, dirnames, filenames in os.walk(root):
            dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
            for filename in filenames:
                path = Path(current) / filename
                rel = path.relative_to(root).as_posix()
                files.append(rel)

    filtered: List[str] = []
    for rel in files:
        path = normalize_repo_path(root, rel)
        if path is None or not path.is_file():
            continue
        parts = set(Path(rel).parts)
        if parts & SKIP_DIRS:
            continue
        if path.suffix in SKIP_SUFFIXES or path.name in SKIP_SUFFIXES:
            continue
        if is_probably_text(path):
            filtered.append(Path(rel).as_posix())

    return sorted(set(filtered), key=str.lower)


def count_tokens(text: str) -> Dict[str, Any]:
    try:
        import tiktoken  # type: ignore

        enc = tiktoken.get_encoding("cl100k_base")
        return {"tokens": len(enc.encode(text)), "mode": "tiktoken"}
    except Exception:
        return {"tokens": (len(text) + 3) // 4, "mode": "estimate"}


class ContextPackHandler(BaseHTTPRequestHandler):
    root: Path

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def send_json(self, data: Dict[str, Any], status: int = 200) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def read_json_body(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8") if length else "{}"
        return json.loads(raw or "{}")

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            payload = INDEX_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if parsed.path == "/api/files":
            files = collect_files(self.root)
            important = [path for path in IMPORTANT_FILES if path in files]
            self.send_json({"files": files, "important": important, "token_mode": count_tokens("")["mode"]})
            return

        if parsed.path == "/api/file":
            query = parse_qs(parsed.query)
            rel = query.get("path", [""])[0]
            path = normalize_repo_path(self.root, rel)
            if path is None or not path.is_file():
                self.send_json({"error": "Invalid or missing file path"}, 400)
                return
            if not is_probably_text(path):
                self.send_json({"error": "File is not a supported text file"}, 400)
                return
            try:
                content = path.read_text(encoding="utf-8", errors="replace")
                self.send_json({"path": rel, "content": content})
            except Exception as exc:
                self.send_json({"error": str(exc)}, 500)
            return

        self.send_json({"error": "Not found"}, 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/count":
            data = self.read_json_body()
            self.send_json(count_tokens(str(data.get("text", ""))))
            return

        if parsed.path == "/api/save":
            data = self.read_json_body()
            rel = str(data.get("path") or DEFAULT_OUTPUT_PATH)
            content = str(data.get("content") or "")
            path = normalize_repo_path(self.root, rel)
            if path is None:
                self.send_json({"error": "Output path must stay inside the repo"}, 400)
                return
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
                self.send_json({"path": path.relative_to(self.root).as_posix(), "bytes": len(content.encode("utf-8"))})
            except Exception as exc:
                self.send_json({"error": str(exc)}, 500)
            return

        self.send_json({"error": "Not found"}, 404)


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Start a localhost context pack picker for ChatGPT-WebView.")
    parser.add_argument("--root", default=".", help="Repo root to serve. Defaults to current directory.")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host. Keep 127.0.0.1 unless you know why you need otherwise.")
    parser.add_argument("--port", type=int, default=8765, help="Local port. Default: 8765.")
    parser.add_argument("--no-open", action="store_true", help="Do not open the browser automatically.")
    args = parser.parse_args(list(argv) if argv is not None else None)

    root = find_repo_root(Path(args.root))
    if not root.exists() or not root.is_dir():
        print(f"Root does not exist or is not a directory: {root}", file=sys.stderr)
        return 2

    ContextPackHandler.root = root
    server = ThreadingHTTPServer((args.host, args.port), ContextPackHandler)
    url = f"http://{args.host}:{args.port}"
    print(f"Context Pack UI: {url}")
    print(f"Serving repo root: {root}")
    print("Local use only. Press Ctrl+C to stop.")

    if not args.no_open:
        time.sleep(0.2)
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Context Pack UI.")
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
