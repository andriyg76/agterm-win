# Local and WSL catalog overlay integration cases. Dot-sourced by shell-cases.ps1 after wsl-cases.ps1 (uses Get-WSLServer, $absent).

$overlayFixtures = Join-Path $PSScriptRoot "fixtures"
$overlayBogusSession = "00000000-0000-0000-0000-000000000011"

function Initialize-OverlayServerLaunch {
    param([string]$State)
    $dist = if ($env:AGTERM_WIN_GATE_WSL) { $env:AGTERM_WIN_GATE_WSL } else { $absent }
    Set-RemoteProperties $State @($dist) @{ $dist = "atLaunch" }
}

# Returns $null on success, or an array of failure strings.
function Connect-OverlayServerCatalogSession {
    param($Shell)
    $state = $Shell.State
    $dist = $env:AGTERM_WIN_GATE_WSL
    $failures = @()
    $server = Wait-Until { $s = Get-WSLServer $state $dist; if ($s.started) { $s } } 20
    if (-not $server) { return ,@("$dist did not start") }
    $connected = Wait-Until { $s = Get-WSLServer $state $dist; if ($s.connected) { $s } } 120
    if (-not $connected) { return ,@("AGTERM_WIN_GATE_WSL=$dist never reached connected") }
    $tree = (Invoke-Ctl $state @("tree", "--window", $connected.id)).result.tree
    $workspace = @($tree.workspaces | Select-Object -First 1)
    if (-not $workspace) { return ,@("no server workspace in tree") }
    $row = Invoke-Ctl $state @("session", "new", "--workspace", $workspace.id)
    if (-not $row.ok) { return ,@("session new on server replied $($row | ConvertTo-Json -Compress)") }
    $id = $row.result.id
    Invoke-Ctl $state @("session", "select", "--target", $id) | Out-Null
    $node = Wait-Until { Get-Node $state $id }
    if (-not $node) { return ,@("new server session $id is missing from tree") }
    if ($node.presenters.presenter -ne $true) { $failures += "presenter is not true: $($node.presenters | ConvertTo-Json -Compress)" }
    if ($failures.Count) { return ,$failures }
    $id
}

$shellPreparations["overlay-server-disconnected"] = { param($state) Initialize-OverlayServerLaunch $state }
$shellPreparations["overlay-server-program"] = { param($state) Initialize-OverlayServerLaunch $state }
$shellPreparations["overlay-server-html"] = { param($state) Initialize-OverlayServerLaunch $state }
$shellPreparations["presentation-surfaces"] = { param($state) Initialize-OverlayServerLaunch $state }

# Local ctl refusals without opening a program overlay.
$shellCases["overlay-local-refusals"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $bogus = "00000000-0000-0000-0000-000000000099"
    $missing = Invoke-Ctl $state @("session", "overlay", "open", "echo x", "--target", $bogus)
    if ($missing.error -ne "no such session: $bogus") { $failures += "missing session replied $($missing | ConvertTo-Json -Compress)" }
    $id = New-PowerShellSession $state
    if (-not $id) { return $failures + @("no local session for overlay refusals") }
    $noOverlay = Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)
    if ($noOverlay.error -ne "no overlay") { $failures += "overlay text with no overlay replied $($noOverlay | ConvertTo-Json -Compress)" }
    $closeEmpty = Invoke-Ctl $state @("session", "overlay", "close", "--target", $id)
    if ($closeEmpty.error -ne "no overlay") { $failures += "overlay close with no overlay replied $($closeEmpty | ConvertTo-Json -Compress)" }
    $failures
}

# an overlay takes the keyboard: Close Session's chord closes it and leaves the session; an exited --wait one closes on a key
$shellCases["overlay-keys"] = {
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

$shellCases["overlay-local-program"] = {
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

$shellCases["overlay-local-html"] = {
    param($Shell)
    $state = $Shell.State
    $page = Join-Path $overlayFixtures "overlay-page.html"
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
    if ([IO.Path]::GetFullPath($node.htmlOverlays[0].file) -ne [IO.Path]::GetFullPath($page)) { $failures += "tree file is '$($node.htmlOverlays[0].file)'" }
    Save-Snapshot $Shell "overlay-html"
    $noRead = Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)
    if ($noRead.error -ne "no overlay to read: the slot holds an html page") { $failures += "overlay text replied $($noRead | ConvertTo-Json -Compress)" }
    Invoke-Ctl $state @("session", "overlay", "close", "--target", $id) | Out-Null
    if (-not (Wait-Until { -not (Get-Node $state $id).overlay } 10)) { $failures += "overlay stayed on tree after close" }
    $failures
}

# Stage B smoke: synthetic WSL, overlay ctl on unknown catalog id, tree stays up.
$shellCases["overlay-server-disconnected"] = {
    param($Shell)
    $state = $Shell.State
    $dist = if ($env:AGTERM_WIN_GATE_WSL) { $env:AGTERM_WIN_GATE_WSL } else { $absent }
    $failures = @()
    $server = Wait-Until { $s = Get-WSLServer $state $dist; if ($s.started) { $s } } 20
    if (-not $server) { return @("$dist did not start: $((Get-WSLServer $state $dist) | ConvertTo-Json -Compress)") }
    $refusal = Invoke-Ctl $state @("session", "overlay", "open", "echo smoke", "--target", $overlayBogusSession)
    if ($refusal.error -ne "no such session: $overlayBogusSession") { $failures += "missing session replied $($refusal | ConvertTo-Json -Compress)" }
    if (-not (Wait-Until { (Invoke-Ctl $state @("tree")).ok } 5)) { $failures += "tree stopped answering after overlay refusal" }
    if (-not $env:AGTERM_WIN_GATE_WSL) {
        if ($server.connected) { $failures += "$absent reads connected on the smoke path" }
    }
    $failures
}

# Stage B full gate: program overlay on a connected catalog session (needs AGTERM_WIN_GATE_WSL).
$shellCases["overlay-server-program"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @(& $shellCases["overlay-server-disconnected"] $Shell)
    if ($failures) { return $failures }
    if (-not $env:AGTERM_WIN_GATE_WSL) { return @() }

    $session = Connect-OverlayServerCatalogSession $Shell
    if ($session -is [System.Array]) { return @($session) }
    $id = $session

    $mark = "overlay-server-gate"
    Invoke-Ctl $state @("session", "overlay", "open", "echo $mark", "--target", $id) | Out-Null
    $node = Wait-Until { $n = Get-Node $state $id; if ($n.overlay) { $n } } 30
    if (-not $node) { return $failures + @("tree never reported overlay on $id") }
    if (-not (Wait-Until { (Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)).result.text -match $mark } 30)) {
        $failures += "overlay text is '$((Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)).result.text)'"
    }
    Invoke-Ctl $state @("session", "overlay", "close", "--target", $id) | Out-Null
    if (-not (Wait-Until { -not (Get-Node $state $id).overlay } 15)) { $failures += "overlay stayed on tree after close" }
    $failures
}

# Stage D on catalog session: --html when presenter (needs AGTERM_WIN_GATE_WSL).
$shellCases["overlay-server-html"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @(& $shellCases["overlay-server-disconnected"] $Shell)
    if ($failures) { return $failures }
    if (-not $env:AGTERM_WIN_GATE_WSL) { return @() }

    $page = Join-Path $overlayFixtures "overlay-page.html"
    if (-not (Test-Path $page)) { return @("missing fixture $page") }

    $session = Connect-OverlayServerCatalogSession $Shell
    if ($session -is [System.Array]) { return @($session) }
    $id = $session

    $open = Invoke-Ctl $state @("session", "overlay", "open", "--html", $page, "--target", $id)
    if (-not $open.ok) { return @("server html overlay open replied $($open | ConvertTo-Json -Compress)") }
    $node = Wait-Until {
        $n = Get-Node $state $id
        if ($n.htmlOverlays -and $n.htmlOverlays[0].state -eq "loaded") { $n }
    } 45
    if (-not $node) {
        return $failures + @("server html overlay never reached loaded: $((Get-Node $state $id).htmlOverlays | ConvertTo-Json -Compress)")
    }
    Save-Snapshot $Shell "overlay-server-html"
    $noRead = Invoke-Ctl $state @("session", "overlay", "text", "--target", $id)
    if ($noRead.error -ne "no overlay to read: the slot holds an html page") { $failures += "overlay text replied $($noRead | ConvertTo-Json -Compress)" }
    Invoke-Ctl $state @("session", "overlay", "close", "--target", $id) | Out-Null
    if (-not (Wait-Until { -not (Get-Node $state $id).htmlOverlays } 15)) { $failures += "html overlay stayed on tree after close" }
    $failures
}

# Stage E: disconnected smoke; live ask/pick/HUD need AGTERM_WIN_GATE_WSL (docs/remote-linux-gate.md).
$shellCases["presentation-surfaces"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @(& $shellCases["overlay-server-disconnected"] $Shell)
    if ($failures) { return $failures }
    if (-not $env:AGTERM_WIN_GATE_WSL) { return @() }
    @("presentation-surfaces full gate: use docs/remote-linux-gate.md (WSL presentation UI gate)")
}

# Back-compat: old case names (deprecated; use overlay-local-program / overlay-local-html).
$shellCases["overlay"] = $shellCases["overlay-local-program"]
$shellCases["overlay-html"] = $shellCases["overlay-local-html"]