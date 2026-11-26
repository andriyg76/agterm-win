# remote.properties agterm-server cases. They need no WSL: a remote defined on a distribution no machine has stands in,
# so a start runs wsl.exe and its server stays unconnected, which is all these read back. Dot-sourced by shell-cases.ps1
# after settings-cases.ps1, whose helpers they use.

$absent = "agterm-test-absent"
# TDM_CLICK_BUTTON and the first-start question's button ids (NativeDialog.cpp): 100 + ServerLaunch.Answer's index
$clickButton = 0x0466; $neverAskButton = 102

# Set-RemoteProperties seeds the case's config with `remote.properties` defining the remotes `$Names` as WSL
# distributions, and `$Launch` as native.json's serverLaunch choices when given.
function Set-RemoteProperties([string]$State, [string[]]$Names, [hashtable]$Launch) {
    $config = Join-Path $State "config"
    New-Item -ItemType Directory -Force -Path $config | Out-Null
    $lines = @("# seeded by the integration case") + @($Names | % { "$_ = wsl.exe -d $_ -e" })
    [IO.File]::WriteAllText((Join-Path $config "remote.properties"), ($lines -join "`n") + "`n")
    if ($Launch) {
        $choices = ($Launch.Keys | % { "`"$($_ -replace '"','\"')`": `"$($Launch[$_])`"" }) -join ", "
        Set-Content (Join-Path $State "native.json") "{`"serverLaunch`": {$choices}}"
    }
}

# Get-WSLServer is the remote's window as window list reports it: open while its server is started, connected while
# its stream is, and the launch choice native.json saves for it.
function Get-WSLServer([string]$State, [string]$Distribution) {
    $window = (Invoke-Ctl $State @("window", "list")).result.windows | ? { $_.remote.host -eq $Distribution } | Select-Object -First 1
    if ($window) {
        [pscustomobject]@{ distribution = $Distribution; id = $window.id; started = [bool]$window.open
                           connected = $window.remote.state -eq "connected"; launch = Get-ServerLaunch $State $Distribution }
    }
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

# Get-NoticeBar is the window's notice bar while it shows a notice, nil while it is hidden.
function Get-NoticeBar([IntPtr]$Window) { [AgtermWin32]::VisibleChildren($Window, "agterm-notice-bar") | Select-Object -First 1 }

# Get-WSLBootstrapNotices is the notice the bar shows, its window text, empty while the bar is hidden.
function Get-WSLBootstrapNotices($Shell) {
    $bar = Get-NoticeBar (Get-ShellWindow $Shell)
    if ($bar) { @([AgtermWin32]::TextOf($bar) | ? { $_ }) } else { @() }
}

function Get-AgtermWinLog([string]$State) {
    $path = Join-Path $State "agterm-win.log"
    if (-not (Test-Path $path)) { return "" }
    Get-Content $path -Raw -Encoding UTF8
}

# with nothing chosen, agterm opens without starting any server or asking, and writes remote.properties from what WSL
# lists, whose remotes window list then reports
$shellCases["wsl-not-at-launch"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    Start-Sleep -Seconds 3
    $log = Get-Content (Join-Path $state "agterm-win.log") -Raw
    if (-not $log.Contains("no agterm-server starts at launch")) { $failures += "the log does not say no server starts" }
    if ([AgtermWin32]::Visible($Shell.Process.Id, "#32770")) { $failures += "a dialog opened at launch" }
    $file = Join-Path $state "config\remote.properties"
    $written = Wait-Until { if (Test-Path $file) { Get-Content $file -Raw -Encoding UTF8 } } 30
    if (-not $written) { return $failures + @("agterm did not write $file") }
    if (-not $written.Contains("# remote.properties:")) { $failures += "the written remote.properties has no header: $written" }
    $defined = @($written -split "`n" | ? { $_ -match '^\s*[^#!\s]' } | % { ($_ -split '\s*=\s*', 2)[0].Trim() })
    $list = Invoke-Ctl $state @("window", "list")
    if (-not $list.ok) { return $failures + @("window list replied $($list | ConvertTo-Json -Compress)") }
    $running = @($list.result.windows | ? { $_.open })
    if ($running) { $failures += "servers started at launch: $(($running.remote.host) -join ', ')" }
    $listed = @($list.result.windows | % { $_.remote.host })
    if (($listed -join ",") -ne ($defined -join ",")) { $failures += "window list reports '$($listed -join ',')', remote.properties defines '$($defined -join ',')'" }
    $tree = (Invoke-Ctl $state @("tree")).result.tree
    $remote = @($tree.workspaces.sessions | ? { $_.remoteHost })
    if ($remote) { $failures += "tree has server sessions with no server started: $(($remote.remoteHost) -join ', ')" }
    $processes = Get-ServerProcesses $Shell
    if ($processes) { $failures += "wsl.exe runs for a server: $($processes[0].CommandLine)" }
    $failures
}

# a remote chosen to start at launch starts without asking; Settings ▸ General changes the choice, and agterm leaves the
# seeded remote.properties as it was
$shellPreparations["wsl-at-launch"] = {
    param($state) Set-RemoteProperties $state @($absent) @{ $absent = "atLaunch" }
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
    if (-not $log.Contains("starting agterm-server in $absent")) { $failures += "the log does not show the start" }
    if (-not $log.Contains("remote inspect $absent")) { $failures += "the log does not show remote inspect before connect" }
    if (-not $log.Contains("remote ensure $absent")) { $failures += "the log does not show remote ensure" }
    $notice = Wait-Until {
        $text = (Get-WSLBootstrapNotices $Shell) -join "`n"
        if ($text -match "not reachable|Checking $absent") { $text }
    } 20
    if (-not $notice) { $failures += "the sidebar notice did not show the probe outcome" }
    Save-Snapshot $Shell "started"

    $seeded = Get-Content (Join-Path $state "config\remote.properties") -Raw
    if (-not $seeded.StartsWith("# seeded by the integration case")) { $failures += "agterm rewrote the seeded remote.properties: $seeded" }
    $unknown = Invoke-Ctl $state @("window", "remote", "open", "agterm-test-nowhere")
    if ($unknown.ok -or $unknown.error -ne "window.remote.open: agterm-test-nowhere is not defined in remote.properties") {
        $failures += "an undefined remote replied $($unknown | ConvertTo-Json -Compress)"
    }
    $again = Invoke-Ctl $state @("window", "remote", "open", $absent)
    if (-not $again.ok -or $again.result.id -ne $server.id) { $failures += "opening a started server replied $($again | ConvertTo-Json -Compress)" }

    $settings = Open-Settings $Shell (Get-ShellWindow $Shell) "general"
    if (-not $settings) { return $failures + @("Settings did not open") }
    $box = [AgtermWin32]::VisibleChildren($settings, "Button") | ? { [AgtermWin32]::TextOf($_) -eq $absent } | Select-Object -First 1
    if (-not $box) { return $failures + @("Settings ▸ General has no $absent check box") }
    Save-Snapshot $Shell "settings-servers" $settings
    if ([int][AgtermSettings]::SendMessageW($box, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero) -ne 1) { $failures += "the check box is not ticked" }  # BM_GETCHECK
    [AgtermSettings]::SendMessageW($box, 0x00F1, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # BM_SETCHECK unchecked
    if (-not (Close-Settings $settings $true)) { return $failures + @("OK did not close Settings") }
    if ((Get-ServerLaunch $state $absent) -ne "manual") { $failures += "unticking left native.json '$(Get-ServerLaunch $state $absent)'" }
    $settings = Open-Settings $Shell (Get-ShellWindow $Shell) "general"
    $box = [AgtermWin32]::VisibleChildren($settings, "Button") | ? { [AgtermWin32]::TextOf($_) -eq $absent } | Select-Object -First 1
    if (-not $box) { return $failures + @("Settings did not open again on the $absent check box") }
    if ([int][AgtermSettings]::SendMessageW($box, 0x00F0, [IntPtr]::Zero, [IntPtr]::Zero) -ne 0) { $failures += "the check box is ticked after the untick" }
    [AgtermSettings]::SendMessageW($box, 0x00F1, [IntPtr]1, [IntPtr]::Zero) | Out-Null  # BM_SETCHECK checked
    if (-not (Close-Settings $settings $true)) { return $failures + @("OK did not close Settings the second time") }
    if ((Get-ServerLaunch $state $absent) -ne "atLaunch") { $failures += "ticking left native.json '$(Get-ServerLaunch $state $absent)'" }
    $failures
}

# Get-ListedDistribution is the first distribution `wsl -l -q` lists that can hold a server, nil without one.
function Get-ListedDistribution {
    $ErrorActionPreference = "Continue"
    $listed = @((& wsl.exe -l -q 2>$null | Out-String) -replace "`0", "" -split "`r?`n" | % { $_.Trim() } | ? { $_ -and $_ -notlike "docker-desktop*" })
    if ($LASTEXITCODE -eq 0) { $listed | Select-Object -First 1 }
}

# a first launch with a start-at-launch choice and no remote.properties writes the file before the start resolves the
# name; on a machine with a distribution the start then finds it defined
$atLaunchUnseeded = Get-ListedDistribution
if (-not $atLaunchUnseeded) { $atLaunchUnseeded = $absent }
$shellPreparations["wsl-at-launch-unseeded"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$atLaunchUnseeded`": `"atLaunch`"}}"
}
$shellCases["wsl-at-launch-unseeded"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $started = Wait-Until { $log = Get-AgtermWinLog $state; if ($log.Contains("starting agterm-server in $atLaunchUnseeded")) { $log } } 30
    if (-not $started) { return @("$atLaunchUnseeded did not start") }
    $wrote = $started.IndexOf("native shell: wrote ")
    if ($wrote -lt 0 -or $wrote -gt $started.IndexOf("starting agterm-server in $atLaunchUnseeded")) {
        $failures += "the start ran before remote.properties was written"
    }
    if ($atLaunchUnseeded -ne $absent) {
        $null = Wait-Until { (Get-AgtermWinLog $state).Contains("remote ensure $atLaunchUnseeded") } 30
        if ((Get-AgtermWinLog $state).Contains("not defined in remote.properties")) { $failures += "the start found $atLaunchUnseeded undefined" }
        $notice = (Get-WSLBootstrapNotices $Shell) -join "`n"
        if ($notice -match "not reachable|refuse|failed") { $failures += "the notice bar shows '$notice'" }
    }
    $failures
}

# --wsl starts that server, asking first while nothing is chosen; Don't ask again starts it and saves manual
$shellPreparations["wsl-first-start"] = { param($state) Set-RemoteProperties $state @($absent) }
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
    if ($server.launch -ne "manual") { $failures += "window list's server reads launch '$($server.launch)', not manual" }
    if ((Get-ServerLaunch $state $absent) -ne "manual") { $failures += "native.json keeps '$(Get-ServerLaunch $state $absent)'" }
    $failures
}

# at-launch ensure reports why a missing distribution stays disconnected, without attempting a GitHub download
$shellPreparations["wsl-ensure-probe"] = {
    param($state) Set-RemoteProperties $state @($absent) @{ $absent = "atLaunch" }
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
    if (-not $log.Contains("remote inspect $absent")) { $failures += "log lacks remote inspect" }
    if ($log -match "downloading https://github.com/umputun/agterm/releases") { $failures += "ensure tried to download agterm-server for an unreachable distribution" }
    if (-not ((Get-WSLBootstrapNotices $Shell) -join "`n" -match "not reachable")) {
        $failures += "sidebar notice does not explain the unreachable remote"
    }
    if (-not $log.Contains("distributionUnreachable") -and -not ($log -match "remote ensure $absent.*refuse")) {
        $failures += "log does not record a refused ensure plan"
    }
    Save-Snapshot $Shell "ensure-probe"
    $failures
}

# opening an already-started server's window runs ensure again when still disconnected; a session needs a connection,
# and an ssh host is no remote agterm-win reaches
$shellPreparations["wsl-ensure-reprobe"] = {
    param($state) Set-RemoteProperties $state @($absent) @{ $absent = "atLaunch" }
}
$shellCases["wsl-ensure-reprobe"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $null = Wait-Until { (Get-WSLServer $state $absent).started } 25
    Start-Sleep -Seconds 2
    $before = ([regex]::Matches((Get-AgtermWinLog $state), "remote inspect $absent")).Count
    $again = Invoke-Ctl $state @("window", "remote", "open", $absent)
    if (-not $again.ok) { $failures += "window remote open replied $($again | ConvertTo-Json -Compress)" }
    Start-Sleep -Seconds 2
    $after = ([regex]::Matches((Get-AgtermWinLog $state), "remote inspect $absent")).Count
    if ($after -le $before) { $failures += "window remote open did not run another inspect ($before -> $after)" }
    $session = Invoke-Ctl $state @("session", "new", "--remote", $absent)
    if ($session.ok -or $session.error -ne "no connection to $absent") {
        $failures += "a session on a disconnected server replied $($session | ConvertTo-Json -Compress)"
    }
    $ssh = Invoke-Ctl $state @("window", "remote", "open", "buildbox")
    if ($ssh.ok -or $ssh.error -ne "window.remote.open: buildbox is not defined in remote.properties") {
        $failures += "an ssh host replied $($ssh | ConvertTo-Json -Compress)"
    }
    $failures
}

# --install-server on an unreachable remote surfaces install failure in the log and notice instead of hanging, and
# agtermctl server install, which that install runs, fails the same way
# a chosen launch keeps the first-start question, which holds the main thread, out of this case
$shellPreparations["wsl-install-unreachable"] = {
    param($state) Set-RemoteProperties $state @($absent) @{ $absent = "manual" }
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
    $ErrorActionPreference = "Continue"
    $env:AGTERM_STATE_DIR = $state
    try {
        $errors = @(& $ctl server install $absent 2>&1 | ? { $_ -is [System.Management.Automation.ErrorRecord] } | % { $_.ToString() })
        $code = $LASTEXITCODE
    } finally { Remove-Item Env:AGTERM_STATE_DIR }
    $reason = if ($errors) { $errors[0] -replace '^Error: ', '' }
    if ($code -ne 1) { $failures += "agtermctl server install exited $code" }
    if (-not $reason) { $failures += "agtermctl server install printed no reason" }
    elseif ($notice -and -not $notice.Contains($reason.Trim())) { $failures += "the CLI's reason '$reason' is not the notice's '$notice'" }
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

# Get-BarButtons are the action buttons the bar drew left of its close, left to right, as spans of its own pixels: a row
# through the buttons above their labels, read right to left from the close, differs from the bar's background there.
function Get-BarButtons([IntPtr]$Window, [IntPtr]$Bar) {
    $dpi = [AgtermWin32]::GetDpiForWindow($Window)
    $rect = Get-ScreenRect $Bar
    $origin = Get-ScreenPoint $Window 0 0
    $shot = Get-Shot $Window
    try {
        $dx = $rect.Left - $origin.X + $shot.X; $dy = $rect.Top - $origin.Y + $shot.Y
        $y = [int][Math]::Floor((8 * $dpi + 48) / 96)
        $background = $shot.Bitmap.GetPixel($dx + [int](8 * $dpi / 96), $dy + 3)
        $spans = @(); $right = $null
        $x = ($rect.Right - $rect.Left) - [int][Math]::Floor((40 * $dpi + 48) / 96) - 1
        $stop = [int][Math]::Floor((173 * $dpi + 48) / 96)
        for (; $x -ge $stop -and $spans.Count -lt 2; $x--) {
            $c = $shot.Bitmap.GetPixel($dx + $x, $dy + $y)
            $button = ([Math]::Abs($c.R - $background.R) + [Math]::Abs($c.G - $background.G) + [Math]::Abs($c.B - $background.B)) -gt 15
            if ($button -and $null -eq $right) { $right = $x }
            elseif (-not $button -and $null -ne $right) {
                if ($right - $x -ge [int](24 * $dpi / 96)) { $spans = @([pscustomobject]@{ Left = $x + 1; Right = $right + 1 }) + $spans }
                $right = $null
            }
        }
        $spans
    } finally { $shot.Bitmap.Dispose() }
}

# Click-Bar presses and releases the bar's left button at its own point, as a click does.
function Click-Bar([IntPtr]$Bar, [int]$X, [int]$Y) {
    $at = [AgtermWin32]::At($X, $Y)
    [AgtermWin32]::PostMessageW($Bar, 0x0201, [IntPtr]1, $at) | Out-Null
    [AgtermWin32]::PostMessageW($Bar, 0x0202, [IntPtr]::Zero, $at) | Out-Null
}

# Drag-Bar presses the bar's body, moves `$By` pixels and releases there, as a drag of the bar does.
function Drag-Bar([IntPtr]$Bar, [int]$X, [int]$Y, [int]$By) {
    [AgtermWin32]::PostMessageW($Bar, 0x0201, [IntPtr]1, [AgtermWin32]::At($X, $Y)) | Out-Null
    [AgtermWin32]::PostMessageW($Bar, 0x0200, [IntPtr]1, [AgtermWin32]::At($X, $Y + $By)) | Out-Null
    [AgtermWin32]::PostMessageW($Bar, 0x0202, [IntPtr]::Zero, [AgtermWin32]::At($X, $Y + $By)) | Out-Null
}

# the unreachable distribution's error shows in the notice bar under the title bar, with Retry and Open Log; a drag takes
# it to the bottom and another brings it back, the terminal reflowing each time; Retry probes again; the close dismisses
# it; its colors follow the theme
$shellPreparations["notice-bar"] = {
    param($state) Set-RemoteProperties $state @($absent) @{ $absent = "atLaunch" }
}
$shellCases["notice-bar"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $failures = @()
    $window = Get-ShellWindow $Shell
    Invoke-Ctl $state @("theme", "set", "Dracula") | Out-Null
    $bar = Wait-Until { $b = Get-NoticeBar $window; if ($b -and [AgtermWin32]::TextOf($b) -match "not reachable") { $b } } 30
    if (-not $bar) { return @("no error notice on screen: '$(Get-WSLBootstrapNotices $Shell)'") }
    $terminal = Get-Panes $window | Select-Object -First 1
    if (-not $terminal) { return $failures + @("no terminal on screen") }
    $client = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetClientRect($window, [ref]$client) | Out-Null
    $topEdge = (Get-ScreenPoint $window 0 0).Y
    $bottomEdge = (Get-ScreenPoint $window 0 $client.Bottom).Y
    $barRect = Get-ScreenRect $bar
    $height = $barRect.Bottom - $barRect.Top
    $dpi = [AgtermWin32]::GetDpiForWindow($window)
    if ($height -ne [int][Math]::Floor((34 * $dpi + 48) / 96)) { $failures += "the bar is $height px at $dpi dpi" }
    if ($barRect.Top -gt $topEdge + [int](48 * $dpi / 96)) { $failures += "the bar is not under the title bar: it starts $($barRect.Top - $topEdge) px down" }
    if ((Get-ScreenRect $terminal).Top -lt $barRect.Bottom) { $failures += "the terminal starts above the bar's bottom at the top" }
    $stripe = Get-BarPixel $window $bar 1 ([int]($height / 2))
    $background = Get-BarPixel $window $bar ([int](8 * $dpi / 96)) 3
    if (-not ($stripe.R -gt $stripe.G + 40 -and $stripe.R -gt $stripe.B)) { $failures += "the error stripe is not red: $stripe" }
    if ((Get-Brightness $background) -gt 0x60) { $failures += "the bar is not dark under Dracula: $background" }
    $buttons = @(Get-BarButtons $window $bar)
    if ($buttons.Count -ne 2) { $failures += "the error shows $($buttons.Count) action button(s), not Retry and Open Log" }
    Save-Snapshot $Shell "notice-top"

    Note "drag to the bottom"
    $x = [int](12 * $dpi / 96); $y = [int]($height / 2)
    Drag-Bar $bar $x $y $client.Bottom
    # the bar follows the pointer before the release settles it, so the release's log line says it moved; polling
    # native.json instead would hold it open against the save
    if (-not (Wait-Until { (Get-AgtermWinLog $state).Contains("native shell: notice bar at bottom") } 5)) {
        $failures += "the drop did not move the bar to the bottom"
    }
    Start-Sleep -Milliseconds 300
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

    Note "drag to the top"
    Drag-Bar $bar $x $y (-$client.Bottom)
    if (-not (Wait-Until { (Get-AgtermWinLog $state).Contains("native shell: notice bar at top") } 5)) {
        $failures += "the drop did not move the bar back to the top"
    }
    Start-Sleep -Milliseconds 300
    if ((Get-Saved $state).noticeBarPosition -ne "top") { $failures += "native.json keeps '$((Get-Saved $state).noticeBarPosition)' after the drag to the top" }
    if ((Get-ScreenRect $bar).Top -gt $topEdge + [int](48 * $dpi / 96)) { $failures += "the bar did not return under the title bar" }
    if ((Get-ScreenRect $terminal).Top -lt (Get-ScreenRect $bar).Bottom) { $failures += "the terminal starts above the bar after the drag to the top" }
    Save-Snapshot $Shell "notice-top-light"

    if ($buttons.Count -eq 2) {
        Note "Retry"
        $before = ([regex]::Matches((Get-AgtermWinLog $state), "remote inspect $absent")).Count
        Click-Bar $bar ([int](($buttons[0].Left + $buttons[0].Right) / 2)) $y
        if (-not (Wait-Until { (Get-AgtermWinLog $state).Contains("notice action retry for $absent") } 5)) { $failures += "Retry did not run the retry action" }
        if (-not (Wait-Until { ([regex]::Matches((Get-AgtermWinLog $state), "remote inspect $absent")).Count -gt $before } 20)) {
            $failures += "Retry did not probe $absent again"
        }
        $bar = Wait-Until { $b = Get-NoticeBar $window; if ($b -and [AgtermWin32]::TextOf($b) -match "not reachable") { $b } } 30
        if (-not $bar) { return $failures + @("the error did not come back after Retry: '$(Get-WSLBootstrapNotices $Shell)'") }
    }

    Note "close"
    $barRect = Get-ScreenRect $bar
    Click-Bar $bar ($barRect.Right - $barRect.Left - [int](12 * $dpi / 96)) ([int]($height / 2))
    if (-not (Wait-Until { -not [AgtermWin32]::IsWindowVisible($bar) } 5)) { $failures += "the bar stays on screen with its only notice dismissed" }
    if ((Get-ScreenRect $terminal).Top -gt (Get-ScreenPoint $window 0 ([int](48 * $dpi / 96))).Y) { $failures += "the terminal did not take the bar's place" }
    Save-Snapshot $Shell "notice-dismissed"
    $failures
}

$localWorkspace = "00000000-0000-0000-0000-00000000000A"

$shellPreparations["overlay-server-program"] = {
    param($state)
    $dist = if ($env:AGTERM_WIN_GATE_WSL) { $env:AGTERM_WIN_GATE_WSL } else { $absent }
    Set-RemoteProperties $state @($dist) @{ $dist = "atLaunch" }
}

# Stage B: ctl overlay on a catalog session when connected; smoke on a synthetic remote when not (docs/plans/20261124-server-program-overlay.md).
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
