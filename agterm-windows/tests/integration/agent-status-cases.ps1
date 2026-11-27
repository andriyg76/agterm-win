# What agents report: status, context and info read back through the tree and the title bar, cleared by typing; and the
# bundled PowerShell adapters run as Claude Code and Codex run their hooks, with the hook's JSON on stdin. Dot-sourced
# by shell-cases.ps1 after title-bar-cases.ps1, whose AgtermWin32 helpers it uses.

# Invoke-Adapter runs a staged adapter as an agent's hook does, inside session `$Id`, with `$Payload` on stdin.
function Invoke-Adapter([string]$State, [string]$Id, [string]$Script, [string[]]$Arguments, [string]$Payload, [string]$Pane = "left") {
    $ErrorActionPreference = "Continue"
    $env:AGTERM_STATE_DIR = $State
    $env:AGTERM_SESSION_ID = $Id
    $env:AGTERM_PANE = $Pane
    $env:AGTERMCTL = $ctl
    try {
        $path = Join-Path (Split-Path $exe) "agent-status\$Script"
        $argv = @("-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $path) + $Arguments
        if ($Payload) { $out = $Payload | & powershell.exe @argv 2>&1 } else { $out = & powershell.exe @argv 2>&1 }
        "$out"
    } finally {
        Remove-Item Env:AGTERM_STATE_DIR, Env:AGTERM_SESSION_ID, Env:AGTERM_PANE, Env:AGTERMCTL
    }
}

# status sets per pane: a split's block holds while the main pane finishes, typing into that pane clears it; context
# shows in the title bar and info under the row's name, and both clear
$shellCases["agent-status"] = {
    param($Shell)
    $state = $Shell.State
    $id = New-PowerShellSession $state
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
    $failures = @()
    Invoke-Ctl $state @("session", "status", "active", "--blink", "--target", $id) | Out-Null
    $node = Get-Node $state $id
    if ($node.status -ne "active" -or -not $node.statusBlink -or "$($node.activePanes)" -ne "left") {
        $failures += "after active: $($node | Select-Object status, statusBlink, activePanes | ConvertTo-Json -Compress)"
    }
    Invoke-Ctl $state @("session", "split", "on", "--target", $id) | Out-Null
    if (-not (Wait-Until { (Get-PaneText $state $id "right") -match ">" } 30)) { $failures += "the split never reached its prompt" }
    Invoke-Ctl $state @("session", "status", "blocked", "--pane", "right", "--target", $id) | Out-Null
    Invoke-Ctl $state @("session", "status", "completed", "--target", $id) | Out-Null
    $node = Get-Node $state $id
    if ($node.status -ne "blocked" -or $node.statusPane -ne "right") { $failures += "the left pane's completed replaced the right pane's block: $($node.status)/$($node.statusPane)" }
    $refusal = Invoke-Ctl $state @("session", "status", "busy", "--target", $id)
    if ($refusal.ok -or $refusal.error -ne "invalid status") { $failures += "busy replied $($refusal | ConvertTo-Json -Compress)" }

    Invoke-Ctl $state @("session", "context", "PR 12", "--target", $id) | Out-Null
    Invoke-Ctl $state @("session", "info", "**3** tests", "--markdown", "--target", $id) | Out-Null
    $node = Get-Node $state $id
    if ($node.context -ne "PR 12") { $failures += "context is '$($node.context)'" }
    if ("$($node.info)" -notmatch "tests") { $failures += "info is '$($node.info)'" }
    $window = Get-ShellWindow $Shell
    if ($window -and ([AgtermWin32]::TextOf($window)) -notlike "*PR 12") { $failures += "the title is '$([AgtermWin32]::TextOf($window))'" }
    Save-Snapshot $Shell "status-context-info"

    Invoke-Ctl $state @("session", "type", "--target", $id, "--pane", "right", "y") | Out-Null
    if (-not (Wait-Until { (Get-Node $state $id).status -ne "blocked" } 5)) { $failures += "typing into the right pane left its block" }
    Invoke-Ctl $state @("session", "context", "--clear", "--target", $id) | Out-Null
    Invoke-Ctl $state @("session", "info", "--clear", "--target", $id) | Out-Null
    $node = Get-Node $state $id
    if ($node.context -or $node.info) { $failures += "clear left context '$($node.context)', info '$($node.info)'" }
    $failures
}

# the Claude Code adapter: a Stop with a running background task stays working, a subagent's active never covers a
# finished turn; the Codex adapter: a Stop asking a question blocks, its watcher blocks on an approval prompt on screen
# and works again once it is gone, and the memory thread's events report nothing
$shellCases["agent-hooks"] = {
    param($Shell)
    $state = $Shell.State
    $id = New-PowerShellSession $state
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
    $failures = @()
    $status = { (Get-Node $state $id).status }
    $out = Invoke-Adapter $state $id "agterm-claude-status.ps1" @("active", "--blink") '{"hook_event_name":"UserPromptSubmit"}'
    if ($out) { $failures += "the Claude adapter printed '$out'" }
    if ((& $status) -ne "active") { $failures += "UserPromptSubmit left '$(& $status)'" }
    Invoke-Adapter $state $id "agterm-claude-status.ps1" @("completed", "--auto-reset") `
        '{"hook_event_name":"Stop","background_tasks":[{"type":"shell","status":"running"}]}' | Out-Null
    if ((& $status) -ne "active") { $failures += "Stop with a running shell left '$(& $status)'" }
    Invoke-Adapter $state $id "agterm-claude-status.ps1" @("completed", "--auto-reset") '{"hook_event_name":"Stop"}' | Out-Null
    if ((& $status) -ne "completed") { $failures += "Stop left '$(& $status)'" }
    Invoke-Adapter $state $id "agterm-claude-status.ps1" @("active", "--blink") '{"hook_event_name":"PostToolUse","agent_id":"a1"}' | Out-Null
    if ((& $status) -ne "completed") { $failures += "a subagent's PostToolUse replaced completed with '$(& $status)'" }

    Invoke-Adapter $state $id "agterm-codex-status.ps1" @("user-prompt-submit") '{"transcript_path":null}' | Out-Null
    if ((& $status) -ne "completed") { $failures += "the memory thread's prompt reported '$(& $status)'" }
    Invoke-Adapter $state $id "agterm-codex-status.ps1" @("stop") '{"last_assistant_message":"Should I push the branch?"}' | Out-Null
    if ((& $status) -ne "blocked") { $failures += "a Stop asking a question left '$(& $status)'" }
    Invoke-Adapter $state $id "agterm-codex-status.ps1" @("stop") '{"last_assistant_message":"Done. Press `?` for help."}' | Out-Null
    if ((& $status) -ne "completed") { $failures += "a Stop with a ? in code left '$(& $status)'" }

    $env:AGTERM_CODEX_WATCH_INTERVAL = "0.5"
    $env:AGTERM_CODEX_WATCH_MAX_CHECKS = "60"
    try {
        Invoke-Adapter $state $id "agterm-codex-status.ps1" @("user-prompt-submit") '{"transcript_path":"t.jsonl"}' | Out-Null
    } finally { Remove-Item Env:AGTERM_CODEX_WATCH_INTERVAL, Env:AGTERM_CODEX_WATCH_MAX_CHECKS }
    if ((& $status) -ne "active") { $failures += "user-prompt-submit left '$(& $status)'" }
    Invoke-Ctl $state @("session", "type", "--target", $id, "Write-Host 'Allow command? Press enter to confirm'`r") | Out-Null
    if (-not (Wait-Until { (& $status) -eq "blocked" } 15)) { $failures += "the watcher never blocked on the prompt: '$(& $status)'" }
    Save-Snapshot $Shell "codex-prompt"
    Invoke-Ctl $state @("session", "type", "--target", $id, "Clear-Host`r") | Out-Null
    if (-not (Wait-Until { (& $status) -eq "active" } 15)) { $failures += "the watcher never reported work after the prompt went: '$(& $status)'" }
    Invoke-Adapter $state $id "agterm-codex-status.ps1" @("stop") '{"last_assistant_message":"Done."}' | Out-Null
    if ((& $status) -ne "completed") { $failures += "the last Stop left '$(& $status)'" }
    $failures
}

# events.read: a `session wait` started in another process returns once the status lands, and a running
# `agtermctl events` prints it
$shellCases["events-wait"] = {
    param($Shell)
    $state = $Shell.State
    $id = New-PowerShellSession $state
    if (-not $id) { return @("the session did not start") }
    $failures = @()
    $out = Join-Path $Shell.Dir "events.jsonl"
    $env:AGTERM_STATE_DIR = $state
    try {
        $wait = Start-Process -FilePath $ctl -ArgumentList @("session", "wait", "--until", "completed", "--timeout", "10", "--target", $id) `
            -NoNewWindow -PassThru
        $stream = Start-Process -FilePath $ctl -ArgumentList @("events", "--kind", "status", "--json") -NoNewWindow -PassThru `
            -RedirectStandardOutput $out
    } finally { Remove-Item Env:AGTERM_STATE_DIR }
    # a PassThru process reports no ExitCode unless its handle was taken before it exited
    $wait.Handle | Out-Null
    Start-Sleep -Seconds 2
    Invoke-Ctl $state @("session", "status", "completed", "--target", $id) | Out-Null
    if (-not $wait.WaitForExit(15000)) {
        $failures += "session wait never returned"
        Stop-Process -Id $wait.Id -Force -ErrorAction SilentlyContinue
    } elseif ($wait.ExitCode -ne 0) { $failures += "session wait exited $($wait.ExitCode)" }
    $printed = Wait-Until { if (Test-Path $out) { $text = Get-Content $out -Raw; if ($text -match '"completed"') { $text } } } 10
    if (-not $printed) { $failures += "agtermctl events printed '$(if (Test-Path $out) { Get-Content $out -Raw })'" }
    Stop-Process -Id $stream.Id -Force -ErrorAction SilentlyContinue
    $failures
}
