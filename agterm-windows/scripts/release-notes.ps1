# Builds GitHub release notes for agterm-win from commits and merged PRs since the previous v<agterm>.<n> tag.
# With OPENAI_API_KEY set, summarizes via the chat API; otherwise emits a structured list from gh/git.
#   scripts\release-notes.ps1 -Version 0.44.1.5 [-BaseBranch windows-port] [-OutFile notes.md]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$BaseBranch = "windows-port",
    [string]$OutFile = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$agterm = Get-Content (Join-Path $root "AGTERM_VERSION") -TotalCount 1
if ($Version -notmatch "^$([regex]::Escape($agterm))\.\d+$") { throw "VERSION must be $agterm.N, got $Version" }

$build = [int]($Version -replace "^$([regex]::Escape($agterm))\.", "")
if ($build -le 1) {
    $prefix = ($agterm -split '\.')[0..1] -join '.'
    $minor = [int](($agterm -split '\.')[1])
    $prevAgterm = if ($minor -gt 0) { "$prefix.$($minor - 1)" } else { throw "no previous agterm series for $Version" }
    $prevTag = git tag --list "v$prevAgterm.*" | ForEach-Object { if ($_ -match "^v$([regex]::Escape($prevAgterm))\.(\d+)$") { [pscustomobject]@{ Tag = $_; N = [int]$Matches[1] } } } |
        Sort-Object N -Descending | Select-Object -First 1 -ExpandProperty Tag
    if (-not $prevTag) { $prevTag = "v$prevAgterm.0" }
} else {
    $prevTag = "v$agterm.$($build - 1)"
}

$range = if (git rev-parse --verify "${prevTag}^{commit}" 2>$null) { "$prevTag..HEAD" } else { "HEAD" }
$commits = @(git log $range --no-merges --pretty=format:"%h %s" 2>$null)
$merges = @(git log $range --merges --pretty=format:"%h %s" 2>$null)

$since = ""
if (git rev-parse --verify "${prevTag}^{commit}" 2>$null) {
    $since = git log -1 --format=%Y-%m-%dT%H:%M:%SZ $prevTag
}
$repo = (git -C $root remote get-url origin) -replace '^https://github\.com/', '' -replace '\.git$', ''
$prs = @()
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $ghArgs = @("pr", "list", "--repo", $repo, "--state", "merged", "--base", $BaseBranch, "--limit", "100",
        "--json", "number,title,body,mergedAt,url")
    if ($since) { $ghArgs += @("--search", "merged:>=$($since.Substring(0, 10))") }
    $raw = gh @ghArgs 2>$null | ConvertFrom-Json
    if ($raw) { $prs = @($raw) }
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
        $lines.Add("")
    }
    if ($commits.Count) {
        $lines.Add("### Commits")
        foreach ($line in $commits) { $lines.Add("- $line") }
        $lines.Add("")
    }
    if ($merges.Count -and -not $prs.Count) {
        $lines.Add("### Merge commits")
        foreach ($line in $merges) { $lines.Add("- $line") }
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
Group changes under Markdown headings:
- **Features** — user-visible behavior; each bullet names the feature briefly and cites task/plan/issue references ONLY when they appear in a PR title or body (e.g. stage D0, docs/plans/..., #NN).
- **Refactoring and infrastructure** — modules or areas touched without a user-facing feature (e.g. agtermCore, NativeShell, CI).
Skip merge-commit noise and duplicate bullets. Do not invent issue numbers. Keep bullets short. Do not repeat the version line (it is added separately).
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
    $model = if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "GPT-6.1-terra" }
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