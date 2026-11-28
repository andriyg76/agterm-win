# Builds GitHub release notes for agterm-win from commits and merged PRs since the previous release tag reachable from HEAD.
# With OPENAI_API_KEY set, summarizes via the chat API; otherwise emits a structured list from gh/git.
#   scripts\release-notes.ps1 -Version 0.44.2 [-BaseTag v0.44.1.11] [-BaseBranch windows-port] [-OutFile notes.md]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$BaseTag = "",
    [string]$BaseBranch = "",
    [string]$OutFile = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$agterm = Get-Content (Join-Path $root "AGTERM_VERSION") -TotalCount 1
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION must be a.b.c, got $Version" }
if (-not $BaseBranch) { $BaseBranch = git -C $root rev-parse --abbrev-ref HEAD }

$prevTag = if ($BaseTag) { $BaseTag } else { git -C $root describe --tags --abbrev=0 --match "v[0-9]*" HEAD 2>$null }

$range = if (git rev-parse --verify "${prevTag}^{commit}" 2>$null) { "$prevTag..HEAD" } else { "HEAD" }
$commits = @(git log $range --no-merges --pretty=format:"%h %s" 2>$null)
$merges = @(git log $range --merges --pretty=format:"%h %s" 2>$null)

$since = ""
if (git rev-parse --verify "${prevTag}^{commit}" 2>$null) {
    $since = git log -1 --format=%cI $prevTag
}
$repo = (git -C $root remote get-url origin) -replace '^https://github\.com/', '' -replace '\.git$', ''
$prs = @()
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $ghArgs = @("pr", "list", "--repo", $repo, "--state", "merged", "--base", $BaseBranch, "--limit", "100",
        "--json", "number,title,body,mergedAt,url")
    if ($since) { $ghArgs += @("--search", "merged:>=$($since.Substring(0, 10))") }
    $raw = gh @ghArgs 2>$null | ConvertFrom-Json
    if ($raw) { $prs = @($raw | Where-Object { -not $since -or [datetimeoffset]$_.mergedAt -gt [datetimeoffset]$since }) }
}

$header = @"
agterm-win $Version (agterm $agterm)

"@

function Format-Fallback {
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($prs.Count) {
        $lines.Add("### Features and fixes")
        foreach ($pr in $prs) {
            $lines.Add("- #$($pr.number) [$($pr.title)]($($pr.url))")
        }
    } elseif ($commits.Count) {
        $lines.Add("### Commits")
        foreach ($line in $commits) { $lines.Add("- $line") }
    }
    $lines -join "`n"
}

function Invoke-OpenAiNotes {
    param([string]$ApiKey, [string]$Model)
    $payload = @{
        commits = $commits
        merge_commits = $merges
        merged_pull_requests = $prs | ForEach-Object { @{ number = $_.number; title = $_.title; body = $_.body; url = $_.url; mergedAt = $_.mergedAt } }
        version = $Version
        previous_tag = $prevTag
        range = $range
    } | ConvertTo-Json -Depth 6 -Compress
    $system = @"
You write GitHub release notes for agterm-win (Windows port of agterm).
Describe what changed for users; do not list commits. Base each bullet on the merged pull requests (title and body), using commits only for work no PR covers.
Group changes under Markdown headings, omitting empty ones:
- **Features** — new or changed user-visible behavior, one short bullet per feature, ending with its PR link (#NN).
- **Fixes** — user-visible bugs fixed: what was wrong and is now right, ending with its PR link (#NN).
- **Refactoring and infrastructure** — one short bullet per area touched without a user-facing change (e.g. agtermCore, tests, CI, packaging).
Merge related PRs and commits into one bullet. Skip merge commits and duplicates. Do not invent issue numbers. Keep bullets short. Do not repeat the version line (it is added separately).
"@
    $user = "Summarize this release payload as release notes body (Markdown only, no top-level H1):`n$payload"
    $body = @{
        model = $Model
        messages = @(
            @{ role = "system"; content = $system }
            @{ role = "user"; content = $user }
        )
        temperature = 0.2
    } | ConvertTo-Json -Depth 5
    $response = Invoke-RestMethod -Method Post -Uri "https://api.openai.com/v1/chat/completions" `
        -Headers @{ Authorization = "Bearer $ApiKey" } `
        -ContentType "application/json; charset=utf-8" `
        -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $text = $response.choices[0].message.content.Trim()
    if ($text -match '^```') { $text = ($text -replace '^```(?:markdown)?\s*', '' -replace '\s*```$', '').Trim() }
    $text
}

$body = if ($env:OPENAI_API_KEY) {
    $model = if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "gpt-6.1-terra" }
  try {
      Invoke-OpenAiNotes -ApiKey $env:OPENAI_API_KEY -Model $model
  } catch {
      Write-Warning "OpenAI release notes failed: $_; using fallback"
      Format-Fallback
  }
} else {
    Format-Fallback
}

$notes = $header + $body
if ($OutFile) {
    [IO.File]::WriteAllText($OutFile, $notes, [Text.UTF8Encoding]::new($false))
} else {
    $notes
}