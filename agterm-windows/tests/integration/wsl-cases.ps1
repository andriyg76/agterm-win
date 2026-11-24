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
    $log = Get-Content (Join-Path $state "agterm-win.log") -Raw
    if (-not $log.Contains("starting agterm-server in WSL $absent")) { $failures += "the log does not show the start" }
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

# Stage B: overlay on an agterm-server session (presentation + job helper). run.ps1 SKIPs until implemented.
$shellCases["overlay-server-program"] = {
    param($Shell)
    @("overlay-server-program should be skipped by run.ps1 until stage B ships")
}
