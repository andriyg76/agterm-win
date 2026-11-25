# WSL agterm-server cases. They need no WSL: a distribution no machine has stands in, so a start runs wsl.exe and its
# server stays unconnected, which is all these read back. Dot-sourced by shell-cases.ps1 after settings-cases.ps1, whose
# helpers they use.

$absent = "agterm-test-absent"
# TDM_CLICK_BUTTON and the first-start question's button ids (NativeDialog.cpp): 100 + ServerLaunch.Answer's index
$clickButton = 0x0466; $neverAskButton = 102

function Get-WSLServer([string]$State, [string]$Distribution) {
    (Invoke-Ctl $State @("wsl", "list")).result.wsl | ? { $_.distribution -eq $Distribution } | Select-Object -First 1
}

function Get-ServerLaunch([string]$State, [string]$Distribution) {
    $saved = Get-Saved $State
    if ($saved.serverLaunch) { $saved.serverLaunch.$Distribution }
}

# Get-ServerProcesses are the wsl.exe processes the window started for a server: its catalog stream and short commands.
function Get-ServerProcesses($Shell) {
    @(Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe' AND ParentProcessId = $($Shell.Process.Id)" |
        ? { $_.CommandLine -match "agtermctl" })
}

# Get-WSLBootstrapNotices are the notice bar's notices, as notice list reads them back.
function Get-WSLBootstrapNotices($Shell) {
    @((Invoke-Ctl $Shell.State @("notice", "list")).result.noticeBar.notices | % { $_.text } | ? { $_ })
}

function Get-AgtermWinLog([string]$State) {
    $path = Join-Path $State "agterm-win.log"
    if (-not (Test-Path $path)) { return "" }
    Get-Content $path -Raw -Encoding UTF8
}

# with nothing chosen, agterm opens without starting any server or asking
$shellCases["wsl-not-at-launch"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    Start-Sleep -Seconds 3
    $log = Get-Content (Join-Path $state "agterm-win.log") -Raw
    if (-not $log.Contains("no agterm-server starts at launch")) { $failures += "the log does not say no server starts" }
    if ([AgtermWin32]::Visible($Shell.Process.Id, "#32770")) { $failures += "a dialog opened at launch" }
    $list = Invoke-Ctl $state @("wsl", "list")
    if (-not $list.ok) { return $failures + @("wsl list replied $($list | ConvertTo-Json -Compress)") }
    $running = @($list.result.wsl | ? { $_.started })
    if ($running) { $failures += "servers started at launch: $(($running.distribution) -join ', ')" }
    $tree = (Invoke-Ctl $state @("tree")).result.tree
    if (@($tree.wslServers).Count -ne @($list.result.wsl).Count) { $failures += "tree wslServers differs from wsl list" }
    $processes = Get-ServerProcesses $Shell
    if ($processes) { $failures += "wsl.exe runs for a server: $($processes[0].CommandLine)" }
    $failures
}

# a distribution chosen to start at launch starts without asking; wsl launch and Settings ▸ General change the choice
$shellPreparations["wsl-at-launch"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$absent`": `"atLaunch`"}}"
}
$shellCases["wsl-at-launch"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $server = Wait-Until { $s = Get-WSLServer $state $absent; if ($s.started) { $s } } 15
    if (-not $server) { return @("$absent did not start: $((Get-WSLServer $state $absent) | ConvertTo-Json -Compress)") }
    if ($server.connected) { $failures += "$absent reads connected" }
    if ($server.launch -ne "atLaunch") { $failures += "$absent launch is '$($server.launch)'" }
    if ([AgtermWin32]::Visible($Shell.Process.Id, "#32770")) { $failures += "a chosen start asked" }
    $log = Get-AgtermWinLog $state
    if (-not $log.Contains("starting agterm-server in WSL $absent")) { $failures += "the log does not show the start" }
    if (-not $log.Contains("wsl inspect $absent")) { $failures += "the log does not show wsl inspect before connect" }
    if (-not $log.Contains("wsl ensure $absent")) { $failures += "the log does not show wsl ensure" }
    $notice = Wait-Until {
        $text = (Get-WSLBootstrapNotices $Shell) -join "`n"
        if ($text -match "not reachable|Checking WSL $absent") { $text }
    } 20
    if (-not $notice) { $failures += "the sidebar notice did not show the probe outcome" }
    Save-Snapshot $Shell "started"

    $off = Invoke-Ctl $state @("wsl", "launch", $absent, "off")
    $offServer = $off.result.wsl | ? { $_.distribution -eq $absent }
    if (-not $off.ok -or $offServer.launch -ne "manual") { $failures += "wsl launch off replied $($off | ConvertTo-Json -Compress -Depth 4)" }
    if ((Get-ServerLaunch $state $absent) -ne "manual") { $failures += "native.json keeps '$(Get-ServerLaunch $state $absent)' after off" }
    $unknown = Invoke-Ctl $state @("wsl", "launch", "agterm-test-nowhere", "on")
    if ($unknown.ok -or $unknown.error -ne "no WSL distribution named agterm-test-nowhere") {
        $failures += "an unknown distribution replied $($unknown | ConvertTo-Json -Compress)"
    }
    $again = Invoke-Ctl $state @("wsl", "start", $absent)
    if (-not $again.ok) { $failures += "starting a started server replied $($again | ConvertTo-Json -Compress)" }
    Invoke-Ctl $state @("wsl", "launch", $absent, "on") | Out-Null

    $window = Get-ShellWindow $Shell
    $settings = Open-Settings $Shell $window "general"
    if (-not $settings) { return $failures + @("Settings did not open") }
    $box = [AgtermWin32]::VisibleChildren($settings, "Button") | ? { [AgtermWin32]::TextOf($_) -eq "WSL $absent" } | Select-Object -First 1
    if (-not $box) { return $failures + @("Settings ▸ General has no WSL $absent check box") }
    Save-Snapshot $Shell "settings-servers" $settings
    if ([int][AgtermSettings]::SendMessageW($box, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero) -ne 1) { $failures += "the check box is not ticked" }  # BM_GETCHECK
    [AgtermSettings]::SendMessageW($box, 0x00F1, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # BM_SETCHECK unchecked
    if (-not (Close-Settings $settings $true)) { return $failures + @("OK did not close Settings") }
    if ((Get-ServerLaunch $state $absent) -ne "manual") { $failures += "unticking left native.json '$(Get-ServerLaunch $state $absent)'" }
    if ((Get-WSLServer $state $absent).launch -ne "manual") { $failures += "unticking left wsl list '$((Get-WSLServer $state $absent).launch)'" }
    $failures
}

# --wsl starts that server, asking first while nothing is chosen; Don't ask again starts it and saves manual
$shellLaunches["wsl-first-start"] = @{ Arguments = "--wsl $absent"; CaseWaits = $true }
$shellCases["wsl-first-start"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    # the question holds the control socket, so nothing asks agtermctl until it is answered
    $question = Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "#32770") | Select-Object -First 1 } 30
    if (-not $question) { return @("the first start did not ask") }
    Save-Snapshot $Shell "question" $question
    [AgtermWin32]::SendMessageW($question, $clickButton, [IntPtr]$neverAskButton, [IntPtr]::Zero) | Out-Null
    # without comctl32 6 the question is a Yes/No/Cancel box, whose Cancel stands for the third answer
    if (-not (Wait-Until { -not [AgtermSettings]::IsWindow($question) } 3)) {
        [AgtermWin32]::PostMessageW($question, 0x0111, [IntPtr]2, [IntPtr]::Zero) | Out-Null
    }
    if (-not (Wait-Until { -not [AgtermSettings]::IsWindow($question) } 10)) { return @("the question did not close on its third answer") }
    if (-not (Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30)) { return @("the control socket did not answer after the question") }
    $server = Wait-Until { $s = Get-WSLServer $state $absent; if ($s.started) { $s } } 15
    if (-not $server) { $failures += "$absent did not start after the answer" }
    if ($server.launch -ne "manual") { $failures += "wsl list launch is '$($server.launch)', not manual" }
    if ((Get-ServerLaunch $state $absent) -ne "manual") { $failures += "native.json keeps '$(Get-ServerLaunch $state $absent)'" }
    $failures
}

# at-launch ensure reports why a missing distribution stays disconnected, without attempting a GitHub download
$shellPreparations["wsl-ensure-probe"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$absent`": `"atLaunch`"}}"
}
$shellCases["wsl-ensure-probe"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $null = Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30
    $server = Wait-Until { $s = Get-WSLServer $state $absent; if ($s.started) { $s } } 20
    if (-not $server) { return @("$absent did not start") }
    if ($server.connected) { $failures += "$absent reads connected for a distribution this machine does not have" }
    $log = Get-AgtermWinLog $state
    if (-not $log.Contains("wsl inspect $absent")) { $failures += "log lacks wsl inspect" }
    if ($log -match "downloading https://github.com/umputun/agterm/releases") { $failures += "ensure tried to download agterm-server for an unreachable distribution" }
    if (-not ((Get-WSLBootstrapNotices $Shell) -join "`n" -match "not reachable")) {
        $failures += "sidebar notice does not explain the unreachable distribution"
    }
    if (-not $log.Contains("distributionUnreachable") -and -not ($log -match "wsl ensure $absent.*refuse")) {
        $failures += "log does not record a refused ensure plan"
    }
    Save-Snapshot $Shell "ensure-probe"
    $failures
}

# wsl start on an already-started server runs ensure again when still disconnected
$shellPreparations["wsl-ensure-reprobe"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$absent`": `"atLaunch`"}}"
}
$shellCases["wsl-ensure-reprobe"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $null = Wait-Until { (Get-WSLServer $state $absent).started } 25
    Start-Sleep -Seconds 2
    $before = ([regex]::Matches((Get-AgtermWinLog $state), "wsl inspect $absent")).Count
    $again = Invoke-Ctl $state @("wsl", "start", $absent)
    if (-not $again.ok) { $failures += "wsl start replied $($again | ConvertTo-Json -Compress)" }
    Start-Sleep -Seconds 2
    $after = ([regex]::Matches((Get-AgtermWinLog $state), "wsl inspect $absent")).Count
    if ($after -le $before) { $failures += "wsl start did not run another inspect ($before -> $after)" }
    $failures
}

# --install-server on an unreachable distribution surfaces install failure in the log and notice instead of hanging
# a chosen launch keeps the first-start question, which holds the main thread, out of this case
$shellPreparations["wsl-install-unreachable"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$absent`": `"manual`"}}"
}
$shellLaunches["wsl-install-unreachable"] = @{ Arguments = "--wsl $absent --install-server" }
$shellCases["wsl-install-unreachable"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $null = Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30
    $log = Wait-Until {
        $text = Get-AgtermWinLog $state
        if ($text -match "server install failed|install failed") { $text }
    } 45
    if (-not $log) { return @("install did not fail visibly on log within 45 s") }
    $notice = Wait-Until {
        $text = (Get-WSLBootstrapNotices $Shell) -join "`n"
        if ($text -match "install failed") { $text }
    } 5
    if (-not $notice) { $failures += "sidebar notice does not report install failure" }
    if ((Get-WSLServer $state $absent).connected) { $failures += "unreachable install left the server connected" }
    Save-Snapshot $Shell "install-unreachable"
    $failures
}

# Get-ScreenRect is a window's rectangle in screen pixels.
function Get-ScreenRect([IntPtr]$Window) {
    $rect = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetWindowRect($Window, [ref]$rect) | Out-Null
    $rect
}

# Get-BarPixel is the color the notice bar painted at its own point, from a picture of the window.
function Get-BarPixel([IntPtr]$Window, [IntPtr]$Bar, [int]$X, [int]$Y) {
    $shot = Get-Shot $Window
    $origin = Get-ScreenPoint $Window 0 0
    $rect = Get-ScreenRect $Bar
    try { $shot.Bitmap.GetPixel($rect.Left - $origin.X + $X + $shot.X, $rect.Top - $origin.Y + $Y + $shot.Y) } finally { $shot.Bitmap.Dispose() }
}

function Get-Brightness($Color) { ($Color.R + $Color.G + $Color.B) / 3 }

# the unreachable distribution's error shows in the notice bar under the title bar; a drag takes it to the bottom and
# notice position brings it back, the terminal reflowing each time; the close dismisses it; its colors follow the theme
$shellPreparations["notice-bar"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$absent`": `"atLaunch`"}}"
}
$shellCases["notice-bar"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $failures = @()
    $window = Get-ShellWindow $Shell
    Invoke-Ctl $state @("theme", "set", "Dracula") | Out-Null
    $notice = Wait-Until {
        $list = Invoke-Ctl $state @("notice", "list")
        $list.result.noticeBar.notices | ? { $_.severity -eq "error" -and $_.text -match "not reachable" } | Select-Object -First 1
    } 30
    if (-not $notice) { return @("no error notice: $((Invoke-Ctl $state @("notice", "list")) | ConvertTo-Json -Compress -Depth 5)") }
    if ((@($notice.actions) -join ",") -ne "retry,openLog") { $failures += "the error offers '$(@($notice.actions) -join ",")'" }
    if ((Invoke-Ctl $state @("tree")).result.tree.noticeBar.position -ne "top") { $failures += "tree does not read the bar at the top" }
    $bar = Wait-Until { [AgtermWin32]::VisibleChildren($window, "agterm-notice-bar") | Select-Object -First 1 } 5
    if (-not $bar) { return $failures + @("no notice bar on screen") }
    if ([AgtermWin32]::TextOf($bar) -ne $notice.text) { $failures += "the bar reads '$([AgtermWin32]::TextOf($bar))'" }
    $terminal = Get-Panes $window | Select-Object -First 1
    if (-not $terminal) { return $failures + @("no terminal on screen") }
    $client = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetClientRect($window, [ref]$client) | Out-Null
    $bottomEdge = (Get-ScreenPoint $window 0 $client.Bottom).Y
    $barRect = Get-ScreenRect $bar
    $height = $barRect.Bottom - $barRect.Top
    $dpi = [AgtermWin32]::GetDpiForWindow($window)
    if ($height -ne [int][Math]::Floor((34 * $dpi + 48) / 96)) { $failures += "the bar is $height px at $dpi dpi" }
    if ((Get-ScreenRect $terminal).Top -lt $barRect.Bottom) { $failures += "the terminal starts above the bar's bottom at the top" }
    $stripe = Get-BarPixel $window $bar 1 ([int]($height / 2))
    $background = Get-BarPixel $window $bar ([int](8 * $dpi / 96)) 3
    if (-not ($stripe.R -gt $stripe.G + 40 -and $stripe.R -gt $stripe.B)) { $failures += "the error stripe is not red: $stripe" }
    if ((Get-Brightness $background) -gt 0x60) { $failures += "the bar is not dark under Dracula: $background" }
    Save-Snapshot $Shell "notice-top"

    Note "drag to the bottom"
    $x = [int](12 * $dpi / 96); $y = [int]($height / 2)
    [AgtermWin32]::PostMessageW($bar, 0x0201, [IntPtr]1, [AgtermWin32]::At($x, $y)) | Out-Null
    [AgtermWin32]::PostMessageW($bar, 0x0200, [IntPtr]1, [AgtermWin32]::At($x, $y + $client.Bottom)) | Out-Null
    [AgtermWin32]::PostMessageW($bar, 0x0202, [IntPtr]::Zero, [AgtermWin32]::At($x, $y + $client.Bottom)) | Out-Null
    if (-not (Wait-Until { (Invoke-Ctl $state @("notice", "list")).result.noticeBar.position -eq "bottom" } 5)) {
        $failures += "the drop did not move the bar to the bottom"
    }
    $barRect = Get-ScreenRect $bar
    if ($barRect.Bottom -ne $bottomEdge) { $failures += "the bar ends at $($barRect.Bottom), not the window's bottom $bottomEdge" }
    $terminalRect = Get-ScreenRect $terminal
    if ($terminalRect.Bottom -gt $barRect.Top) { $failures += "the terminal runs under the bar at the bottom" }
    if ($terminalRect.Top -ge $barRect.Top -or $terminalRect.Top -gt (Get-ScreenPoint $window 0 ([int](48 * $dpi / 96))).Y) {
        $failures += "the terminal did not move up to the title bar"
    }
    if ((Get-Saved $state).noticeBarPosition -ne "bottom") { $failures += "native.json keeps '$((Get-Saved $state).noticeBarPosition)'" }
    Save-Snapshot $Shell "notice-bottom"

    Note "light theme"
    Invoke-Ctl $state @("theme", "set", "Atom One Light") | Out-Null
    Start-Sleep -Milliseconds 500
    $light = Get-BarPixel $window $bar ([int](8 * $dpi / 96)) 3
    if ((Get-Brightness $light) -lt 0xB0) { $failures += "the bar is not light under Atom One Light: $light" }
    Save-Snapshot $Shell "notice-bottom-light"

    $top = Invoke-Ctl $state @("notice", "position", "top")
    if ($top.result.noticeBar.position -ne "top") { $failures += "notice position top replied $($top | ConvertTo-Json -Compress -Depth 5)" }
    if ((Get-ScreenRect $terminal).Top -lt (Get-ScreenRect $bar).Bottom) { $failures += "the terminal starts above the bar after notice position top" }
    Save-Snapshot $Shell "notice-top-light"
    $refused = Invoke-Ctl $state @("notice", "position", "middle")
    if ($refused.ok) { $failures += "notice position middle was accepted" }

    Note "close"
    $barRect = Get-ScreenRect $bar
    $at = [AgtermWin32]::At($barRect.Right - $barRect.Left - [int](12 * $dpi / 96), [int]($height / 2))
    [AgtermWin32]::PostMessageW($bar, 0x0201, [IntPtr]1, $at) | Out-Null
    [AgtermWin32]::PostMessageW($bar, 0x0202, [IntPtr]::Zero, $at) | Out-Null
    $closed = Wait-Until { ((Invoke-Ctl $state @("notice", "list")).result.noticeBar.notices | ? { $_.dismissed }) } 5
    if (-not $closed) { $failures += "the close did not dismiss the notice" }
    if ([AgtermWin32]::IsWindowVisible($bar)) { $failures += "the bar stays on screen with its only notice dismissed" }
    if ((Get-ScreenRect $terminal).Top -gt (Get-ScreenPoint $window 0 ([int](48 * $dpi / 96))).Y) { $failures += "the terminal did not take the bar's place" }
    $again = Invoke-Ctl $state @("notice", "dismiss")
    if ($again.ok -or $again.error -ne "no notice shown") { $failures += "a second dismiss replied $($again | ConvertTo-Json -Compress)" }
    Save-Snapshot $Shell "notice-dismissed"
    $failures
}

$localWorkspace = "00000000-0000-0000-0000-00000000000A"

$shellPreparations["overlay-server-program"] = {
    param($state)
    $dist = if ($env:AGTERM_WIN_GATE_WSL) { $env:AGTERM_WIN_GATE_WSL } else { $absent }
    Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$($dist -replace '"','\"')`": `"atLaunch`"}}"
}

# Stage B: ctl overlay on a catalog session when connected; smoke on synthetic WSL when not (docs/plans/20261124-server-program-overlay.md).
$shellCases["overlay-server-program"] = {
    param($Shell)
    $state = $Shell.State
    $dist = if ($env:AGTERM_WIN_GATE_WSL) { $env:AGTERM_WIN_GATE_WSL } else { $absent }
    $failures = @()
    $server = Wait-Until { $s = Get-WSLServer $state $dist; if ($s.started) { $s } } 20
    if (-not $server) { return @("$dist did not start: $((Get-WSLServer $state $dist) | ConvertTo-Json -Compress)") }

    $bogus = "00000000-0000-0000-0000-000000000011"
    $refusal = Invoke-Ctl $state @("session", "overlay", "open", "echo smoke", "--target", $bogus)
    if ($refusal.error -ne "no such session: $bogus") { $failures += "missing session replied $($refusal | ConvertTo-Json -Compress)" }
    if (-not (Wait-Until { (Invoke-Ctl $state @("tree")).ok } 5)) { $failures += "tree stopped answering after overlay refusal" }

    if (-not $env:AGTERM_WIN_GATE_WSL) {
        if ($server.connected) { $failures += "$absent reads connected on the smoke path" }
        return $failures
    }

    $connected = Wait-Until { $s = Get-WSLServer $state $dist; if ($s.connected) { $s } } 120
    if (-not $connected) { return $failures + @("AGTERM_WIN_GATE_WSL=$dist never reached connected") }

    $tree = (Invoke-Ctl $state @("tree")).result.tree
    $workspace = @($tree.workspaces | Where-Object { $_.id -ne $localWorkspace } | Select-Object -First 1)
    if (-not $workspace) { return $failures + @("no server workspace in tree") }
    $row = (Invoke-Ctl $state @("session", "new", "--workspace", $workspace.id))
    if (-not $row.ok) { return $failures + @("session new on server replied $($row | ConvertTo-Json -Compress)") }
    $id = $row.result.id
    Invoke-Ctl $state @("session", "select", "--target", $id) | Out-Null
    $node = Wait-Until { Get-Node $state $id }
    if (-not $node) { return $failures + @("new server session $id is missing from tree") }
    if ($node.presenters.presenter -ne $true) { $failures += "presenter is not true: $($node.presenters | ConvertTo-Json -Compress)" }

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

$shellPreparations["presentation-surfaces"] = $shellPreparations["overlay-server-program"]

# Stage E: disconnected smoke; live ask/pick/HUD need AGTERM_WIN_GATE_WSL (docs/remote-linux-gate.md).
$shellCases["presentation-surfaces"] = {
    param($Shell)
    $state = $Shell.State
    $dist = if ($env:AGTERM_WIN_GATE_WSL) { $env:AGTERM_WIN_GATE_WSL } else { $absent }
    $failures = @()
    $server = Wait-Until { $s = Get-WSLServer $state $dist; if ($s.started) { $s } } 20
    if (-not $server) { return @("$dist did not start") }
    if (-not $env:AGTERM_WIN_GATE_WSL) {
        if ($server.connected) { $failures += "$absent reads connected on the smoke path" }
        if (-not (Wait-Until { (Invoke-Ctl $state @("tree")).ok } 5)) { $failures += "tree stopped answering" }
        return $failures
    }
    @("presentation-surfaces full gate: use docs/remote-linux-gate.md (WSL presentation UI gate)")
}
