# The message bus between panes, driven from inside them as an agent does: `agtermctl msg` acts as the pane its shell's
# AGTERM_SESSION_ID and AGTERM_PANE_ID name. Dot-sourced by shell-cases.ps1 after agent-status-cases.ps1.

function Get-PaneNode([string]$State, [string]$Id, [string]$Kind = "left") {
    @((Get-Node $State $Id).surfaces) | ? { $_.kind -eq $Kind } | Select-Object -First 1
}

# a pane sends to another session's left pane, which shows it pending in the tree, gets a `message` event, and reads
# and acks it from its own shell; a pane the session lacks is rejected
$shellCases["messages"] = {
    param($Shell)
    $state = $Shell.State
    $sender = New-PowerShellSession $state
    $receiver = New-PowerShellSession $state
    if (-not $sender -or -not $receiver -or -not (Wait-Prompt $state $sender) -or -not (Wait-Prompt $state $receiver)) {
        return @("the sessions never reached their prompts")
    }
    $failures = @()
    $pane = (Get-PaneNode $state $receiver).paneID
    if (-not $pane) { return @("the receiver's left pane reports no paneID") }

    $out = Join-Path $Shell.Dir "message-events.jsonl"
    $env:AGTERM_STATE_DIR = $state
    try {
        $stream = Start-Process -FilePath $ctl -ArgumentList @("events", "--kind", "message", "--json") -NoNewWindow -PassThru `
            -RedirectStandardOutput $out
    } finally { Remove-Item Env:AGTERM_STATE_DIR }
    Start-Sleep -Seconds 2

    Note "send from a pane"
    Invoke-Ctl $state @("session", "type", "--target", $sender,
        "`$env:AGTERM_STATE_DIR='$state'; & '$ctl' msg send --to ${receiver}:left 'hello from a'`r") | Out-Null
    if (-not (Wait-Until { (Get-PaneNode $state $receiver).pendingMessages -eq 1 } 20)) {
        $failures += "the receiver never showed one pending message: $(Get-PaneText $state $sender 'left')"
    }
    $event = Wait-Until { if (Test-Path $out) { $text = Get-Content $out -Raw; if ($text -match [regex]::Escape($pane)) { $text } } } 10
    if (-not $event) { $failures += "no message event for the receiver's pane: '$(if (Test-Path $out) { Get-Content $out -Raw })'" }
    Stop-Process -Id $stream.Id -Force -ErrorAction SilentlyContinue

    Note "read and ack in the receiving pane"
    Invoke-Ctl $state @("session", "type", "--target", $receiver, "`$env:AGTERM_STATE_DIR='$state'; & '$ctl' msg read --ack`r") | Out-Null
    if (-not (Wait-Until { (Get-PaneText $state $receiver "left") -match "hello from a" } 20)) {
        $failures += "msg read did not print the message: $(Get-PaneText $state $receiver 'left')"
    }
    if (-not (Wait-Until { -not (Get-PaneNode $state $receiver).pendingMessages } 10)) { $failures += "the ack left the message pending" }

    Note "an unknown pane is rejected"
    $env:AGTERM_STATE_DIR = $state
    $env:AGTERM_SESSION_ID = $sender
    $env:AGTERM_PANE_ID = (Get-PaneNode $state $sender).paneID
    try {
        $refused = Invoke-Ctl $state @("msg", "send", "--to", "${receiver}:right", "x")
    } finally { Remove-Item Env:AGTERM_STATE_DIR, Env:AGTERM_SESSION_ID, Env:AGTERM_PANE_ID -ErrorAction SilentlyContinue }
    if (-not $refused.ok -or -not @($refused.result.rejected).Count) { $failures += "a missing right pane was not rejected: $($refused | ConvertTo-Json -Compress -Depth 5)" }
    $failures
}
