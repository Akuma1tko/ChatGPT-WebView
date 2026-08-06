[CmdletBinding()]
param(
    [string]$OutputPath = "docs/PROJECT_CONTEXT_PACK.md"
)

$ErrorActionPreference = "Stop"

try {
    $root = (& git rev-parse --show-toplevel 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "git root not found"
    }
} catch {
    $root = Split-Path -Parent $PSScriptRoot
}

Set-Location $root

$importantFiles = @(
    "README.md",
    "docs/SAVED_CONTEXT_MEMORY_DIRECTION.md",
    "docs/PROJECT_GOALS.md",
    "docs/PHASE_1_SUPABASE_MEMORY.md",
    "docs/PHASE_1_DEPLOYMENT_STATUS.md",
    "docs/PHASE_2A_MEMORY_UI.md",
    "docs/COPY_CONTEXT_FOR_CHATGPT.md",
    "docs/PHASE_4B_MULTI_CLOUD_FILE_CONTEXT.md",
    "docs/PHASE_5_VIRTUAL_MCP_MEMORY.md",
    "docs/AUTH_LOGIN_REDIRECT_SETUP.md",
    "docs/CONNECTOR_ASSISTED_SETUP.md",
    "project.yml",
    "supabase/migrations/20260628160000_create_memory_schema.sql",
    "supabase/functions/memory/index.ts",
    "scripts/setup-byo-supabase-memory.sh",
    "AppMemory/MemoryModels.swift",
    "AppMemory/SupabaseMemoryClient.swift",
    "ChatGPTWebView/App/AppModel.swift",
    "ChatGPTWebView/App/RootView.swift",
    "ChatGPTWebView/VirtualMCP/VirtualMCPModels.swift",
    "ChatGPTWebView/VirtualMCP/VirtualMCPMemoryFormatter.swift",
    "ChatGPTWebView/Web/ChatGPTTabView.swift",
    "ChatGPTWebView/Web/ChatGPTWebViewStore.swift",
    "ChatGPTWebView/Web/SecureChatGPTWebView.swift",
    "ChatGPTWebView/Memory/MemoryTestView.swift"
)

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# ChatGPT-WebView Project Context Pack")
$lines.Add("")
$lines.Add("Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
$lines.Add("")
$lines.Add("Purpose: paste this into ChatGPT when starting a new thread so the project state, product direction, Supabase memory schema, and next steps are available without manually restating the context.")
$lines.Add("")
$lines.Add("Important instruction for ChatGPT: use this as repository context. Do not treat this generated pack as canonical source over the files it contains. If there is conflict, prefer the most specific source file section.")
$lines.Add("")
$lines.Add("---")
$lines.Add("")
$lines.Add("## Included files")
$lines.Add("")

foreach ($file in $importantFiles) {
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $lines.Add("- $file")
    } else {
        $lines.Add("- $file (missing)")
    }
}

$includedCount = 0
$missingCount = 0

foreach ($file in $importantFiles) {
    $lines.Add("")
    $lines.Add("---")
    $lines.Add("")
    $lines.Add("# FILE: $file")
    $lines.Add("")

    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $missingCount++
        $lines.Add("Missing from this checkout.")
        continue
    }

    $includedCount++
    $content = Get-Content -LiteralPath $file -Raw
    $lines.Add($content.TrimEnd())
}

$text = $lines -join "`n"
[System.IO.File]::WriteAllText((Join-Path $root $OutputPath), $text + "`n", [System.Text.Encoding]::UTF8)

$byteCount = (Get-Item -LiteralPath $OutputPath).Length
$estimatedTokens = [Math]::Ceiling($byteCount / 4)

Write-Host "Context pack written: $OutputPath"
Write-Host "Included files: $includedCount"
Write-Host "Missing files: $missingCount"
Write-Host "Approx bytes: $byteCount"
Write-Host "Estimated tokens: $estimatedTokens"

if ($estimatedTokens -gt 100000) {
    Write-Warning "CRITICAL: estimated context pack is over 100k tokens. Consider trimming files before pasting."
} elseif ($estimatedTokens -gt 30000) {
    Write-Warning "Estimated context pack is over 30k tokens. This may be too large for some chats."
}
