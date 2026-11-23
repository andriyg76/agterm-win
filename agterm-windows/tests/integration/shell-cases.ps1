# Cases against the full window: each starts agterm-win with its own state directory, drives it with the staged
# agtermctl over that directory's control socket, reads the replies back, and stops the window. Dot-sourced by run.ps1,
# which owns $exe, $Results and the verdict printing; each case returns its failures.

$ctl = Join-Path (Split-Path $exe) "agtermctl.exe"

function Invoke-Ctl([string]$State, [string[]]$Arguments) {
    $env:AGTERM_STATE_DIR = $State
    try { $out = (& $ctl @Arguments --json 2>&1 | Out-String).Trim() } finally { Remove-Item Env:AGTERM_STATE_DIR }
    try { $out | ConvertFrom-Json } catch { [pscustomobject]@{ ok = $false; error = $out } }
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $value = & $Condition
        if ($value) { return $value }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    $null
}

# Start-Shell launches the window on a fresh state directory, after `$Prepare` seeds it, and waits for its socket.
function Start-Shell([string]$Name, [scriptblock]$Prepare) {
    $dir = Join-Path $Results $Name
    $state = Join-Path $dir "state"
    New-Item -ItemType Directory -Force $state | Out-Null
    if ($Prepare) { & $Prepare $state }
    $env:AGTERM_WIN_STATE_DIR = $state
    try { $process = Start-Process -FilePath $exe -PassThru } finally { Remove-Item Env:AGTERM_WIN_STATE_DIR }
    $ready = Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30
    [pscustomobject]@{ Dir = $dir; State = $state; Process = $process; Ready = [bool]$ready }
}

function Stop-Shell($Shell) {
    Stop-Process -Id $Shell.Process.Id -Force -ErrorAction SilentlyContinue
    $Shell.Process.WaitForExit(10000) | Out-Null
}

function Get-Node([string]$State, [string]$Id) {
    $tree = Invoke-Ctl $State @("tree")
    if (-not $tree.ok) { return $null }
    $tree.result.tree.workspaces | % { $_.sessions } | ? { $_.id -eq $Id } | Select-Object -First 1
}

function New-PowerShellSession([string]$State, [string[]]$Extra = @()) {
    $reply = Invoke-Ctl $State (@("session", "new", "--command", "powershell.exe -NoLogo -NoProfile") + $Extra)
    if ($reply.ok) { $reply.result.id } else { $null }
}

# a prompt comes up once PowerShell has run the integration's prompt, which reports the folder
function Wait-Prompt([string]$State, [string]$Id) {
    Wait-Until { (Get-Node $State $Id).cwd } 30
}

$shellCases = [ordered]@{
    # the name follows the folder the shell reports with OSC 9;9; a rename pins one; a blank rename restores the folder's
    "session-name" = {
        param($Shell)
        $state = $Shell.State
        $id = New-PowerShellSession $state
        if (-not $id) { return @("session new failed") }
        if (-not (Wait-Prompt $state $id)) { return @("the shell never reported a folder: $((Get-Node $state $id) | ConvertTo-Json -Compress)") }
        Invoke-Ctl $state @("session", "type", "--target", $id, "cd C:\Windows`r") | Out-Null
        $failures = @()
        $node = Wait-Until { $n = Get-Node $state $id; if ($n.name -eq "Windows") { $n } }
        if (-not $node) { $failures += "name after cd is '$((Get-Node $state $id).name)', not 'Windows'" }
        elseif ($node.cwd -ne "C:\Windows") { $failures += "cwd is '$($node.cwd)'" }
        Invoke-Ctl $state @("session", "rename", "--target", $id, "logs") | Out-Null
        if ((Get-Node $state $id).name -ne "logs") { $failures += "rename to 'logs' did not stick" }
        Invoke-Ctl $state @("session", "rename", "--target", $id, " ") | Out-Null
        if ((Get-Node $state $id).name -ne "Windows") { $failures += "a blank rename left '$((Get-Node $state $id).name)'" }
        $failures
    }

    # notify and a program's OSC 9 count on a session out of view; selecting it clears the count
    "notifications" = {
        param($Shell)
        $state = $Shell.State
        $shown = New-PowerShellSession $state
        $background = New-PowerShellSession $state @("--no-select")
        if (-not $shown -or -not $background) { return @("session new failed") }
        $failures = @()
        $reply = Invoke-Ctl $state @("notify", "--target", $background, "built")
        if (-not $reply.ok -or $reply.result.text) { $failures += "notify replied $($reply | ConvertTo-Json -Compress)" }
        if (-not (Wait-Until { (Get-Node $state $background).unseen -eq 1 })) {
            $failures += "unseen after notify is '$((Get-Node $state $background).unseen)', not 1"
        }
        if (Wait-Prompt $state $background) {
            Invoke-Ctl $state @("session", "type", "--target", $background, ('[Console]::Write("$([char]27)]9;osc-note$([char]7)")' + "`r")) | Out-Null
            if (-not (Wait-Until { (Get-Node $state $background).unseen -eq 2 })) {
                $failures += "OSC 9 did not count: unseen is '$((Get-Node $state $background).unseen)'"
            }
        } else {
            $failures += "the background shell never reached its prompt"
        }
        Invoke-Ctl $state @("session", "select", "--target", $background) | Out-Null
        if ((Get-Node $state $background).unseen) { $failures += "selecting the session left unseen '$((Get-Node $state $background).unseen)'" }
        $failures
    }

    # with banners off, notify says so instead of a plain ok
    "notify-banners-off" = {
        param($Shell)
        $id = New-PowerShellSession $Shell.State
        if (-not $id) { return @("session new failed") }
        $reply = Invoke-Ctl $Shell.State @("notify", "--target", $id, "built")
        if (-not $reply.ok -or "$($reply.result.text)" -notmatch "is off") { @("notify replied $($reply | ConvertTo-Json -Compress)") }
    }

    # theme set takes a bundled theme, reads it back, saves it, refuses an unknown one, and resets bare
    "theme" = {
        param($Shell)
        $state = $Shell.State
        $failures = @()
        $list = Invoke-Ctl $state @("theme", "list")
        if (-not ($list.result.themes -contains "Dracula")) { $failures += "theme list lacks Dracula: $($list | ConvertTo-Json -Compress)" }
        $set = Invoke-Ctl $state @("theme", "set", "Dracula")
        if ($set.result.theme -ne "Dracula") { $failures += "theme set replied $($set | ConvertTo-Json -Compress)" }
        $saved = Get-Content (Join-Path $state "native.json") -Raw | ConvertFrom-Json
        if ($saved.appearance.theme -ne "Dracula") { $failures += "native.json keeps theme '$($saved.appearance.theme)'" }
        $missing = Invoke-Ctl $state @("theme", "set", "No Such Theme")
        if ($missing.ok -or $missing.error -ne "unknown theme: No Such Theme") { $failures += "an unknown theme replied $($missing | ConvertTo-Json -Compress)" }
        $reset = Invoke-Ctl $state @("theme", "set")
        if (-not $reset.ok -or $reset.result.theme) { $failures += "a bare theme set replied $($reset | ConvertTo-Json -Compress)" }
        $failures
    }

    # keymap.conf rebinds a built-in; a reload reports a line agterm-win cannot run
    "keymap" = {
        param($Shell)
        $state = $Shell.State
        $failures = @()
        $list = Invoke-Ctl $state @("keymap", "list")
        $chord = ($list.result.keymap.actions | ? { $_.action -eq "new_session" }).chord
        if ($chord -ne "ctrl+opt+t") { $failures += "new_session is '$chord', not ctrl+opt+t" }
        Add-Content (Join-Path $state "config\keymap.conf") "map ctrl+alt+d toggle_split"
        $reload = Invoke-Ctl $state @("keymap", "reload")
        if (-not $reload.ok -or $reload.result.count -lt 1) { $failures += "keymap reload replied $($reload | ConvertTo-Json -Compress)" }
        $messages = (Invoke-Ctl $state @("keymap", "list")).result.keymap.diagnostics.message
        if (-not ($messages -contains "'toggle_split' is not available on Windows")) { $failures += "diagnostics are $($messages -join ' | ')" }
        $failures
    }
}

# seeds a case's state directory before its window starts; a keymap problem at launch would open a message box
$shellPreparations = @{
    "notify-banners-off" = { param($state) Set-Content (Join-Path $state "native.json") '{"notifications": {"banners": false}}' }
    "keymap" = {
        param($state)
        New-Item -ItemType Directory -Force (Join-Path $state "config") | Out-Null
        Set-Content (Join-Path $state "config\keymap.conf") "map ctrl+alt+t new_session"
    }
}

function Invoke-ShellCase([string]$Name) {
    $shell = Start-Shell $Name $shellPreparations[$Name]
    try {
        $failures = if ($shell.Ready) { @(& $shellCases[$Name] $shell) } else { @("the control socket did not answer within 30 s") }
    } finally {
        Stop-Shell $shell
    }
    $crash = Join-Path $shell.State "crash.log"
    if (Test-Path $crash) { $failures += "crash: " + (Get-Content $crash -Raw).Trim() }
    @($failures | ? { $_ })
}
