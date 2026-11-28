# pick and ask cases: agtermctl opens them with --no-block, keys are posted to the palette field or the ask panel, a
# field's text is set as a user would type it, and every outcome is read back through `pick result` and `ask result`.
# Dot-sourced by shell-cases.ps1 after palette-cases.ps1, whose AgtermInput helpers and Get-Palette it uses.

function Open-Pick([string]$State, [string[]]$Lines, [string[]]$Arguments) {
    $ErrorActionPreference = "Continue"
    $env:AGTERM_STATE_DIR = $State
    try { $out = (($Lines -join "`n") | & $ctl pick @Arguments --no-block --json 2>&1 | Out-String).Trim() }
    finally { Remove-Item Env:AGTERM_STATE_DIR }
    try { $out | ConvertFrom-Json } catch { [pscustomobject]@{ ok = $false; error = $out } }
}

function Get-AskPanel([IntPtr]$Window) { [AgtermWin32]::VisibleChildren($Window, "agterm-ask") | Select-Object -First 1 }

function Get-Outcome([string]$State, [string]$Kind, [string]$Id) {
    # `pick result` and `ask result` print the bare result object, not the server's reply
    Invoke-Ctl $State @($Kind, "result", $Id)
}

function Wait-Outcome([string]$State, [string]$Kind, [string]$Id) {
    Wait-Until { $o = Get-Outcome $State $Kind $Id; if ($o -and $o.result -ne "pending") { $o } } 5
}

$shellCases["pick-ask"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $failures = @()
    $first = Invoke-Ctl $state @("session", "new", "--name", "asked", "--command", "cmd.exe /d /k")
    $second = Invoke-Ctl $state @("session", "new", "--name", "closing", "--command", "cmd.exe /d /k")
    if (-not $first.ok -or -not $second.ok) { return @("could not create test sessions") }
    Invoke-Ctl $state @("session", "select", "--target", $first.result.id) | Out-Null
    $script:InFront = Bring-Front $window

    Note "pick: --prompt, --select, a query, Enter"
    $pick = Open-Pick $state @("one", "two", "three") @("--prompt", "Choose", "--select", "two")
    if (-not $pick.id) { return @("pick open replied $($pick | ConvertTo-Json -Compress)") }
    $palette = Wait-Until { Get-Palette $window } 5
    if (-not $palette) { return @("pick opened no palette") }
    Wait-Until { @(Get-Rows $palette).Count -eq 3 } 5 | Out-Null
    if (((Get-Rows $palette) -join "|") -ne "one|two|three") { $failures += "pick lists '$((Get-Rows $palette) -join "|")', not the caller's order" }
    if ([AgtermInput]::Highlight($palette.List) -ne 1) { $failures += "--select two highlighted row $([AgtermInput]::Highlight($palette.List))" }
    if ((Invoke-Ctl $state @("tree")).result.tree.pickPending -ne $pick.id) { $failures += "the tree's pickPending is not the open pick" }
    Save-Snapshot $Shell "pick"
    [AgtermInput]::SetText($palette.Edit, "thr")
    if (-not (Wait-Until { ((Get-Rows $palette) -join "|") -eq "three" } 5)) { $failures += "'thr' leaves '$((Get-Rows $palette) -join "|")'" }
    Send-Key $palette.Edit 0x0D
    $outcome = Wait-Outcome $state "pick" $pick.id
    if ($outcome.result -ne "picked" -or $outcome.id -ne "three") { $failures += "Enter on three gave $($outcome | ConvertTo-Json -Compress)" }
    if (-not (Wait-Until { -not (Get-Palette $window) } 5)) { $failures += "an answered pick left the palette open" }

    Note "pick: --allow-custom"
    $pick = Open-Pick $state @("one") @("--allow-custom")
    $palette = Wait-Until { Get-Palette $window } 5
    if ($palette) {
        [AgtermInput]::SetText($palette.Edit, "elsewhere")
        if (-not (Wait-Until { ((Get-Rows $palette) -join "|") -eq 'Use "elsewhere"' } 5)) { $failures += "no custom row: '$((Get-Rows $palette) -join "|")'" }
        Send-Key $palette.Edit 0x0D
        $outcome = Wait-Outcome $state "pick" $pick.id
        if ($outcome.result -ne "custom" -or $outcome.query -ne "elsewhere") { $failures += "the custom row gave $($outcome | ConvertTo-Json -Compress)" }
    } else { $failures += "an --allow-custom pick opened no palette" }

    Note "pick: Esc and pick cancel"
    $pick = Open-Pick $state @("one") @()
    $palette = Wait-Until { Get-Palette $window } 5
    if ($palette) {
        Send-Key $palette.Edit 0x1B
        if ((Wait-Outcome $state "pick" $pick.id).result -ne "cancelled") { $failures += "Esc did not cancel the pick" }
    } else { $failures += "a pick for Esc opened no palette" }
    $pick = Open-Pick $state @("one") @()
    if (Wait-Until { Get-Palette $window } 5) {
        Invoke-Ctl $state @("pick", "cancel", $pick.id) | Out-Null
        if (-not (Wait-Until { -not (Get-Palette $window) } 5)) { $failures += "pick cancel left the palette open" }
    } else { $failures += "a pick for pick cancel opened no palette" }

    Note "ask: terminal, arrows and Enter"
    $ask = Invoke-Ctl $state @("ask", "Proceed?", "--message", "from the integration case", "--button", "yes=Yes", "--button", "no=No",
                               "--target", $first.result.id, "--no-block")
    if (-not $ask.id) { return $failures + @("ask open replied $($ask | ConvertTo-Json -Compress)") }
    $panel = Wait-Until { Get-AskPanel $window } 5
    if (-not $panel) { return $failures + @("a terminal ask showed no panel") }
    $node = Get-SessionNodes $state | ? { $_.id -eq $first.result.id }
    if ($node.ask.id -ne $ask.id) { $failures += "the session node's ask is $($node.ask | ConvertTo-Json -Compress)" }
    Save-Snapshot $Shell "ask-terminal"
    Send-Key $panel 0x27
    Send-Key $panel 0x0D
    $outcome = Wait-Outcome $state "ask" $ask.id
    if ($outcome.result -ne "answered" -or $outcome.id -ne "no") { $failures += "Right then Enter gave $($outcome | ConvertTo-Json -Compress)" }
    if (-not (Wait-Until { -not (Get-AskPanel $window) } 5)) { $failures += "an answered ask left its panel" }

    Note "ask: hotkey"
    $ask = Invoke-Ctl $state @("ask", "Keep?", "--button", "keep=Keep", "--button", "drop=Drop", "--hotkey", "drop=d", "--no-block")
    $panel = Wait-Until { Get-AskPanel $window } 5
    if ($panel) {
        Send-Key $panel 0x44
        $outcome = Wait-Outcome $state "ask" $ask.id
        if ($outcome.id -ne "drop") { $failures += "the D hotkey gave $($outcome | ConvertTo-Json -Compress)" }
    } else { $failures += "a hotkey ask showed no panel" }

    Note "ask: --input line"
    $ask = Invoke-Ctl $state @("ask", "Name?", "--button", "ok=OK", "--input", "line", "--placeholder", "a name", "--no-block")
    $panel = Wait-Until { Get-AskPanel $window } 5
    $edit = if ($panel) { [AgtermInput]::Child($panel, "Edit") }
    if ($edit) {
        [AgtermInput]::SetText($edit, "agterm")
        Start-Sleep -Milliseconds 300
        Send-Key $edit 0x0D
        $outcome = Wait-Outcome $state "ask" $ask.id
        if ($outcome.result -ne "answered" -or $outcome.text -ne "agterm") { $failures += "the input ask gave $($outcome | ConvertTo-Json -Compress)" }
    } else { $failures += "an input ask showed no text field" }

    Note "ask: gui style, Esc"
    $ask = Invoke-Ctl $state @("ask", "Allow?", "--button", "ok=OK", "--style", "gui", "--target", $first.result.id, "--no-block")
    $panel = Wait-Until { Get-AskPanel $window } 5
    if ($panel) {
        if ((Invoke-Ctl $state @("tree")).result.tree.askPending -ne $ask.id) { $failures += "the tree's askPending is not the gui ask" }
        Save-Snapshot $Shell "ask-gui"
        Send-Key $panel 0x1B
        if ((Wait-Outcome $state "ask" $ask.id).result -ne "escaped") { $failures += "Esc did not escape the gui ask" }
    } else { $failures += "a gui ask showed no panel" }
    $hidden = Invoke-Ctl $state @("ask", "Allow?", "--button", "ok=OK", "--style", "gui", "--target", $second.result.id, "--no-block")
    if ($hidden.error -ne "session not visible") { $failures += "a gui ask on a session out of view replied $($hidden | ConvertTo-Json -Compress)" }

    Note "ask: cancel, and a closed session ends its ask"
    $ask = Invoke-Ctl $state @("ask", "Wait?", "--button", "ok=OK", "--no-block")
    if (Wait-Until { Get-AskPanel $window } 5) {
        Invoke-Ctl $state @("ask", "cancel", $ask.id) | Out-Null
        if ((Wait-Outcome $state "ask" $ask.id).result -ne "cancelled") { $failures += "ask cancel did not cancel" }
        if (-not (Wait-Until { -not (Get-AskPanel $window) } 5)) { $failures += "ask cancel left its panel" }
    } else { $failures += "an ask for ask cancel showed no panel" }
    $ask = Invoke-Ctl $state @("ask", "Closing?", "--button", "ok=OK", "--target", $second.result.id, "--no-block")
    if (Get-AskPanel $window) { $failures += "an ask on a session out of view showed over the session in view" }
    Invoke-Ctl $state @("session", "close", "--target", $second.result.id) | Out-Null
    if ((Wait-Outcome $state "ask" $ask.id).result -ne "cancelled") { $failures += "closing its session did not cancel the ask" }
    $failures
}
