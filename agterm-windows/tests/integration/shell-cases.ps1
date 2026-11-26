# Cases against the full window: each starts agterm-win with its own state directory, drives it with the staged
# agtermctl over that directory's control socket, reads the replies back, and stops the window. Dot-sourced by run.ps1,
# which owns $exe, $Results and the verdict printing; each case returns its failures.

$ctl = Join-Path (Split-Path $exe) "agtermctl.exe"

# Snapshots go beside a case's results, which CI uploads as the integration-results artifact; one that fails only logs.
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AgtermSnapshot {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[AgtermSnapshot]::SetProcessDPIAware() | Out-Null

function Save-Bitmap([System.Drawing.Bitmap]$Bitmap, [string]$Path) {
    try { $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $Bitmap.Dispose() }
}

# Save-Snapshot draws the shell's window, or `$Window` when given, itself: PW_RENDERFULLCONTENT takes Direct2D's content
# even where something covers it.
function Save-Snapshot($Shell, [string]$Label, [IntPtr]$Window = [IntPtr]::Zero) {
    try {
        $window = $Window
        if ($window -eq [IntPtr]::Zero) {
            $Shell.Process.Refresh()
            $window = $Shell.Process.MainWindowHandle
        }
        if ($window -eq [IntPtr]::Zero) { return }
        $rect = New-Object AgtermSnapshot+Rect
        [AgtermSnapshot]::GetWindowRect($window, [ref]$rect) | Out-Null
        $bitmap = New-Object System.Drawing.Bitmap ([Math]::Max(1, $rect.Right - $rect.Left)), ([Math]::Max(1, $rect.Bottom - $rect.Top))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $dc = $graphics.GetHdc()
        [AgtermSnapshot]::PrintWindow($window, $dc, 2) | Out-Null
        $graphics.ReleaseHdc($dc)
        $graphics.Dispose()
        Save-Bitmap $bitmap (Join-Path $Shell.Dir "$Label.png")
    } catch { Write-Host "snapshot $Label failed: $_" }
}

# Save-ScreenSnapshot takes the whole desktop, for what lies outside the window, a notification's banner.
function Save-ScreenSnapshot($Shell, [string]$Label) {
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        $graphics.Dispose()
        Save-Bitmap $bitmap (Join-Path $Shell.Dir "$Label.png")
    } catch { Write-Host "screen snapshot $Label failed: $_" }
}

# every command but these reads changes what the window shows, so Invoke-Ctl snapshots the window after it
$readCommands = @("tree", "version", "text", "list", "result", "copy", "info", "read")
$stepShells = @{}

function Invoke-Ctl([string]$State, [string[]]$Arguments) {
    # Windows PowerShell 5.1 turns a native program's redirected stderr into errors, which run.ps1's Stop would throw
    $ErrorActionPreference = "Continue"
    $env:AGTERM_STATE_DIR = $State
    try { $out = (& $ctl @Arguments --json 2>&1 | Out-String).Trim() } finally { Remove-Item Env:AGTERM_STATE_DIR }
    $reply = try { $out | ConvertFrom-Json } catch { [pscustomobject]@{ ok = $false; error = $out } }
    $shell = $stepShells[$State]
    $first = [Array]::FindIndex([string[]]$Arguments, [Predicate[string]] { param($a) $a.StartsWith("-") })
    $words = @(if ($first -lt 0) { $Arguments } else { $Arguments | Select-Object -First $first }) | ? { $_ -match '^[a-z][a-z-]*$' }
    if ($shell -and $words -and -not ($words | ? { $readCommands -contains $_ })) {
        $shell.Step++
        Start-Sleep -Milliseconds 250
        Save-Snapshot $shell ("{0:d2}-{1}" -f $shell.Step, ($words -join "-"))
        if ($StepSeconds) { Start-Sleep -Milliseconds ([int]($StepSeconds * 1000)) }
    }
    $reply
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

# Start-Shell launches the window on a fresh state directory, after `$Prepare` seeds it, with `$Launch`'s arguments, and
# waits for its socket unless `$Launch` says the case does: a modal dialog at launch holds every control request.
function Start-Shell([string]$Name, [scriptblock]$Prepare, $Launch) {
    $dir = Join-Path $Results $Name
    $state = Join-Path $dir "state"
    New-Item -ItemType Directory -Force $state | Out-Null
    if ($Prepare) { & $Prepare $state }
    $env:AGTERM_WIN_STATE_DIR = $state
    try {
        $style = if ($Launch.Minimized) { "Minimized" } else { "Normal" }
        $process = if ($Launch.Arguments) { Start-Process -FilePath $exe -ArgumentList $Launch.Arguments -WindowStyle $style -PassThru }
                   else { Start-Process -FilePath $exe -WindowStyle $style -PassThru }
    } finally { Remove-Item Env:AGTERM_WIN_STATE_DIR }
    $ready = if ($Launch.CaseWaits) { $true } else { Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30 }
    $shell = [pscustomobject]@{ Dir = $dir; State = $state; Process = $process; Ready = [bool]$ready; Step = 0 }
    $stepShells[$state] = $shell
    $shell
}

function Stop-Shell($Shell) {
    $stepShells.Remove($Shell.State)
    Stop-Process -Id $Shell.Process.Id -Force -ErrorAction SilentlyContinue
    $Shell.Process.WaitForExit(10000) | Out-Null
    # a killed window leaves its AF_UNIX socket, which nothing can stat, and an artifact upload stops at it
    cmd.exe /d /c del /f /q "$(Join-Path $Shell.State 'agterm.sock')" 2>$null
}

# Get-Node finds a session in the local window's tree, else in a server window's, which bare tree leaves out.
function Get-Node([string]$State, [string]$Id) {
    $tree = Invoke-Ctl $State @("tree")
    if (-not $tree.ok) { return $null }
    $node = $tree.result.tree.workspaces | % { $_.sessions } | ? { $_.id -eq $Id } | Select-Object -First 1
    if ($node) { return $node }
    foreach ($window in @((Invoke-Ctl $State @("window", "list")).result.windows | ? { $_.remote })) {
        $node = (Invoke-Ctl $State @("tree", "--window", $window.id)).result.tree.workspaces | % { $_.sessions } | ? { $_.id -eq $Id } |
            Select-Object -First 1
        if ($node) { return $node }
    }
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
        Save-Snapshot $Shell "after-cd"
        Invoke-Ctl $state @("session", "rename", "--target", $id, "logs") | Out-Null
        if ((Get-Node $state $id).name -ne "logs") { $failures += "rename to 'logs' did not stick" }
        Invoke-Ctl $state @("session", "rename", "--target", $id, " ") | Out-Null
        if ((Get-Node $state $id).name -ne "Windows") { $failures += "a blank rename left '$((Get-Node $state $id).name)'" }
        $failures
    }

    # session new --cwd starts the shell there, which names the session after it
    "session-cwd" = {
        param($Shell)
        $state = $Shell.State
        $id = New-PowerShellSession $state @("--cwd", "C:\Windows\System32")
        if (-not $id) { return @("session new failed") }
        $node = Wait-Until { $n = Get-Node $state $id; if ($n.cwd -eq "C:\Windows\System32") { $n } } 30
        if (-not $node) { return @("cwd is '$((Get-Node $state $id).cwd)', not C:\Windows\System32") }
        if ($node.name -ne "System32") { @("name is '$($node.name)', not System32") }
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
        # a banner slides in over a second or so
        Start-Sleep -Seconds 2
        Save-ScreenSnapshot $Shell "notify-banner"
        Save-Snapshot $Shell "notify-count"
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
        $id = New-PowerShellSession $state
        if ($id -and (Wait-Prompt $state $id)) {
            Invoke-Ctl $state @("session", "type", "--target", $id, ('Write-Host "palette" -NoNewline; 0..15 | % { Write-Host " $_ " -BackgroundColor ([ConsoleColor]$_) -NoNewline }; ""' + "`r")) | Out-Null
            Start-Sleep -Seconds 1
        }
        Save-Snapshot $Shell "dracula"
        $saved = Get-Content (Join-Path $state "native.json") -Raw | ConvertFrom-Json
        if ($saved.appearance.theme -ne "Dracula") { $failures += "native.json keeps theme '$($saved.appearance.theme)'" }
        $missing = Invoke-Ctl $state @("theme", "set", "No Such Theme")
        if ($missing.ok -or $missing.error -ne "unknown theme: No Such Theme") { $failures += "an unknown theme replied $($missing | ConvertTo-Json -Compress)" }
        $reset = Invoke-Ctl $state @("theme", "set")
        if (-not $reset.ok -or $reset.result.theme) { $failures += "a bare theme set replied $($reset | ConvertTo-Json -Compress)" }
        $failures
    }

    # a program overlay floats over the session, reads back, hides, and reports its program's exit code once closed
    "overlay" = {
        param($Shell)
        $state = $Shell.State
        $id = New-PowerShellSession $state
        if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
        $failures = @()
        $open = Invoke-Ctl $state @("session", "overlay", "open", "echo overlay-text& exit /b 4", "--wait", "--size-percent", "60", "--target", $id)
        if (-not $open.ok) { return @("overlay open replied $($open | ConvertTo-Json -Compress)") }
        $node = Get-Node $state $id
        if (-not $node.overlay -or $node.overlaySizePercent -ne 60) { $failures += "tree reads overlay '$($node.overlay)' at '$($node.overlaySizePercent)'" }
        if (-not (Wait-Until { (Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)).result.text -match "overlay-text" })) {
            $failures += "overlay text is '$((Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)).result.text)'"
        }
        if ((Invoke-Ctl $state @("session", "text", "--target", $id)).result.text -match "overlay-text") { $failures += "session text read the overlay" }
        $running = Invoke-Ctl $state @("session", "overlay", "result", "--target", $id)
        if ($running.error -ne "overlay still running") { $failures += "a --wait overlay's result replied $($running | ConvertTo-Json -Compress)" }
        Save-Snapshot $Shell "floating"
        Invoke-Ctl $state @("session", "overlay", "hide", "--target", $id) | Out-Null
        if (@((Get-Node $state $id).hiddenOverlays) -notcontains "session") { $failures += "hide left hiddenOverlays '$((Get-Node $state $id).hiddenOverlays)'" }
        Save-Snapshot $Shell "hidden"
        $again = Invoke-Ctl $state @("session", "overlay", "open", "dir", "--target", $id)
        if ($again.error -ne "overlay hidden") { $failures += "opening over a hidden overlay replied $($again | ConvertTo-Json -Compress)" }
        Invoke-Ctl $state @("session", "overlay", "show", "--target", $id) | Out-Null
        Invoke-Ctl $state @("session", "overlay", "close", "--target", $id) | Out-Null
        $closed = Invoke-Ctl $state @("session", "overlay", "result", "--target", $id)
        if ($closed.result.exitCode -ne 4) { $failures += "result after close replied $($closed | ConvertTo-Json -Compress)" }
        Invoke-Ctl $state @("session", "overlay", "open", "exit /b 7", "--target", $id) | Out-Null
        if (-not (Wait-Until { -not (Get-Node $state $id).overlay })) { $failures += "an overlay without --wait stayed after its program exited" }
        $exited = Invoke-Ctl $state @("session", "overlay", "result", "--target", $id)
        if ($exited.result.exitCode -ne 7) { $failures += "result after exit replied $($exited | ConvertTo-Json -Compress)" }
        $failures
    }

    # an overlay takes the keyboard: Close Session's chord closes it and leaves the session; an exited --wait one closes on a key
    "overlay-keys" = {
        param($Shell)
        $state = $Shell.State
        $id = New-PowerShellSession $state
        if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
        $Shell.Process.Refresh()
        $window = $Shell.Process.MainWindowHandle
        $failures = @()
        Invoke-Ctl $state @("session", "overlay", "open", "ping -n 60 127.0.0.1", "--size-percent", "50", "--target", $id) | Out-Null
        $frame = Wait-Until { [AgtermWin32]::VisibleChildren($window, "agterm-overlay") | Select-Object -First 1 } 5
        if (-not $frame) { return @("no overlay frame came up") }
        $terminal = [AgtermWin32]::VisibleChildren($frame, "agterm-native") | Select-Object -First 1
        Save-Snapshot $Shell "overlay-open"
        [AgtermInput]::FocusOn($terminal)
        [AgtermInput]::SendChord($terminal, 0x4A, $true)
        if (-not (Wait-Until { @((Get-Node $state $id).hiddenOverlays) -contains "session" } 5)) {
            $failures += "Ctrl+Shift+J did not hide the overlay"
        }
        $primary = [AgtermWin32]::VisibleChildren($window, "agterm-native") | Select-Object -First 1
        [AgtermInput]::FocusOn($primary)
        [AgtermInput]::SendChord($primary, 0x4A, $true)
        if (-not (Wait-Until { @((Get-Node $state $id).hiddenOverlays) -notcontains "session" } 5)) {
            $failures += "Ctrl+Shift+J did not restore the overlay"
        }
        [AgtermInput]::FocusOn($terminal)
        [AgtermInput]::SendChord($terminal, 0x57, $false)
        if (-not (Wait-Until { -not (Get-Node $state $id).overlay } 5)) { $failures += "Ctrl+W left the overlay open" }
        if (-not (Get-Node $state $id)) { $failures += "Ctrl+W closed the session under the overlay" }
        if ([AgtermWin32]::VisibleChildren($window, "agterm-overlay").Count) { $failures += "the overlay's frame outlived it" }
        Invoke-Ctl $state @("session", "overlay", "open", "echo done", "--wait", "--target", $id) | Out-Null
        if (-not (Wait-Until { (Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)).result.text -match "Press any key" })) {
            return $failures + "an exited --wait overlay does not offer to close: '$((Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)).result.text)'"
        }
        $frame = [AgtermWin32]::VisibleChildren($window, "agterm-overlay") | Select-Object -First 1
        $terminal = [AgtermWin32]::VisibleChildren($frame, "agterm-native") | Select-Object -First 1
        [AgtermInput]::FocusOn($terminal)
        [AgtermInput]::SendChord($terminal, 0x41, $false)
        if (-not (Wait-Until { -not (Get-Node $state $id).overlay } 5)) { $failures += "a key left the exited --wait overlay open" }
        $result = Invoke-Ctl $state @("session", "overlay", "result", "--target", $id)
        if ($result.result.exitCode -ne 0) { $failures += "result after the key replied $($result | ConvertTo-Json -Compress)" }
        $failures
    }

    # local --html opens a WebView2 page in the overlay slot (stage D0).
    "overlay-html" = {
        param($Shell)
        $state = $Shell.State
        $fixtures = Join-Path $PSScriptRoot "fixtures"
        $page = Join-Path $fixtures "overlay-page.html"
        if (-not (Test-Path $page)) { return @("missing fixture $page") }
        $id = New-PowerShellSession $state
        if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
        $failures = @()
        $open = Invoke-Ctl $state @("session", "overlay", "open", "--html", $page, "--target", $id)
        if (-not $open.ok) { return @("overlay open replied $($open | ConvertTo-Json -Compress)") }
        $node = Wait-Until {
            $n = Get-Node $state $id
            if ($n.htmlOverlays -and $n.htmlOverlays[0].state -eq "loaded") { $n }
        } 45
        if (-not $node) {
            $snap = Get-Node $state $id
            return $failures + @("html overlay never reached loaded: $($snap.htmlOverlays | ConvertTo-Json -Compress)")
        }
        # agtermctl sends the path in URL form, with forward slashes
        if ([IO.Path]::GetFullPath($node.htmlOverlays[0].file) -ne [IO.Path]::GetFullPath($page)) { $failures += "tree file is '$($node.htmlOverlays[0].file)'" }
        Save-Snapshot $Shell "overlay-html"
        $noRead = Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)
        if ($noRead.error -ne "no overlay to read: the slot holds an html page") { $failures += "overlay text replied $($noRead | ConvertTo-Json -Compress)" }
        Invoke-Ctl $state @("session", "overlay", "close", "--target", $id) | Out-Null
        if (-not (Wait-Until { -not (Get-Node $state $id).overlay } 10)) { $failures += "overlay stayed on tree after close" }
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
        Add-Content (Join-Path $state "config\keymap.conf") "map ctrl+alt+d toggle_flag"
        $reload = Invoke-Ctl $state @("keymap", "reload")
        if (-not $reload.ok -or $reload.result.count -lt 1) { $failures += "keymap reload replied $($reload | ConvertTo-Json -Compress)" }
        $messages = (Invoke-Ctl $state @("keymap", "list")).result.keymap.diagnostics.message
        if (-not ($messages -contains "'toggle_flag' is not available on Windows")) { $failures += "diagnostics are $($messages -join ' | ')" }
        $failures
    }
}

. (Join-Path $PSScriptRoot "title-bar-cases.ps1")
. (Join-Path $PSScriptRoot "palette-cases.ps1")
. (Join-Path $PSScriptRoot "settings-cases.ps1")
. (Join-Path $PSScriptRoot "panes-cases.ps1")
. (Join-Path $PSScriptRoot "agent-status-cases.ps1")

# seeds a case's state directory before its window starts; a keymap problem at launch would open a message box
$shellPreparations = @{
    "notify-banners-off" = { param($state) Set-Content (Join-Path $state "native.json") '{"notifications": {"banners": false}}' }
    "keymap" = {
        param($state)
        New-Item -ItemType Directory -Force (Join-Path $state "config") | Out-Null
        Set-Content (Join-Path $state "config\keymap.conf") "map ctrl+alt+t new_session"
    }
}
# what a case's window is started with, when not the bare window
$shellLaunches = @{}
# a case's own time limit, when not $ShellCaseSeconds, and what it removes after its window stops, whether it ran or not
$shellCaseLimits = @{}
$shellTeardowns = @{}

. (Join-Path $PSScriptRoot "wsl-cases.ps1")
. (Join-Path $PSScriptRoot "docker-remote-cases.ps1")

# Note marks a step in the log, so a case that stops shows where.
function Note([string]$Text) { Write-Host ("  {0:HH:mm:ss} {1}" -f (Get-Date), $Text) }

# A window that stops answering blocks SendMessage, PrintWindow and agtermctl for good, so a watchdog process stops
# it after $ShellCaseSeconds: every blocked call then returns and the case fails instead of hanging the run.
$ShellCaseSeconds = 180

function Invoke-ShellCase([string]$Name) {
    $shell = Start-Shell $Name $shellPreparations[$Name] $shellLaunches[$Name]
    Note "$Name started"
    $limit = if ($shellCaseLimits[$Name]) { $shellCaseLimits[$Name] } else { $ShellCaseSeconds }
    $watchdog = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @("-NoProfile", "-Command",
        "Start-Sleep -Seconds $limit; Stop-Process -Id $($shell.Process.Id) -Force -ErrorAction SilentlyContinue")
    $started = Get-Date
    try {
        $failures = if ($shell.Ready) { @(& $shellCases[$Name] $shell) } else { @("the control socket did not answer within 30 s") }
    } catch {
        # a case's own script error fails that case, with where it stopped, and the run goes on
        $failures = @("script error at $(Split-Path -Leaf $_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)")
    } finally {
        Save-Snapshot $shell "final"
        Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue
        Stop-Shell $shell
        if ($shellTeardowns[$Name]) { & $shellTeardowns[$Name] $shell }
    }
    if (((Get-Date) - $started).TotalSeconds -ge $limit) { $failures += "the case did not finish within $limit s; the window was stopped" }
    if (@($failures | ? { $_ }).Count -gt 0) {
        # the app's own account of the case, since CI's uploaded results are not always at hand
        $logFile = Join-Path $shell.State "agterm-win.log"
        if (Test-Path $logFile) { Get-Content $logFile -Tail 25 | % { Write-Host "    log: $_" } }
    }
    $crash = Join-Path $shell.State "crash.log"
    if (Test-Path $crash) { $failures += "crash: " + (Get-Content $crash -Raw).Trim() }
    @($failures | ? { $_ })
}
