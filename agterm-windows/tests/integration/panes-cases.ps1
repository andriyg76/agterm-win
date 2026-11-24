# Split panes, scratch, the quick terminal and the dashboard: driven with agtermctl, the title bar's buttons (clicks
# posted as the mouse sends them) and the keymap's chords (sent to the focused terminal), read back through the tree,
# each pane's text and the windows on screen. Dot-sourced by shell-cases.ps1 after title-bar-cases.ps1 and
# palette-cases.ps1, whose AgtermWin32 and AgtermInput helpers they use.

function Get-Panes([IntPtr]$Window) { @([AgtermWin32]::VisibleChildren($Window, "agterm-native")) }

function Get-PaneText([string]$State, [string]$Id, [string]$Pane) {
    "$((Invoke-Ctl $State @("session", "text", "--target", $Id, "--pane", $Pane)).result.text)"
}

function Get-Rect([IntPtr]$Window) {
    $rect = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetWindowRect($Window, [ref]$rect) | Out-Null
    $rect
}

# a split is a second shell beside the first: typed and read on its own, resized, focused, swapped, hidden and closed
$shellCases["split"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    $id = New-PowerShellSession $state
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
    $failures = @()

    Note "split"
    $reply = Invoke-Ctl $state @("session", "split", "--target", $id)
    if (-not $reply.ok) { return @("session split replied $($reply | ConvertTo-Json -Compress)") }
    $node = Get-Node $state $id
    if (-not $node.split -or -not $node.hasSplit -or $node.splitAxis -ne "vertical" -or -not $node.splitFocused) {
        $failures += "tree reads split '$($node.split)' hasSplit '$($node.hasSplit)' axis '$($node.splitAxis)' focused '$($node.splitFocused)'"
    }
    $panes = Wait-Until { $p = Get-Panes $window; if ($p.Count -eq 2) { , $p } } 5
    if (-not $panes) { $failures += "$((Get-Panes $window).Count) terminal(s) are visible, not 2" }
    if (-not (Wait-Until { (Get-PaneText $state $id "right") -match ">" } 30)) { return $failures + "the split's shell never showed a prompt" }
    Invoke-Ctl $state @("session", "type", "--target", $id, "--pane", "right", "echo split-pane-ok`r") | Out-Null
    if (-not (Wait-Until { (Get-PaneText $state $id "right") -match "split-pane-ok" })) { $failures += "the split pane did not run what was typed into it" }
    if ((Get-PaneText $state $id "left") -match "split-pane-ok") { $failures += "typing into the split reached the primary pane" }
    if ((Invoke-Ctl $state @("session", "text", "--target", $id)).result.text -notmatch "split-pane-ok") { $failures += "session text did not read the focused split" }
    Save-Snapshot $Shell "split"

    Note "resize"
    $resized = Invoke-Ctl $state @("session", "resize", "--target", $id, "--split-ratio", "0.3")
    if ($resized.result.ratio -ne 0.3) { $failures += "resize replied $($resized | ConvertTo-Json -Compress)" }
    if ((Get-Node $state $id).splitRatio -ne 0.3) { $failures += "tree reads splitRatio '$((Get-Node $state $id).splitRatio)'" }
    $panes = Get-Panes $window | Sort-Object { (Get-Rect $_).Left }
    if ($panes.Count -eq 2) {
        $left = Get-Rect $panes[0]; $right = Get-Rect $panes[1]
        $share = ($left.Right - $left.Left) / (($left.Right - $left.Left) + ($right.Right - $right.Left))
        if ([Math]::Abs($share - 0.3) -gt 0.03) { $failures += "the primary pane takes {0:N2} of the width, not 0.30" -f $share }
    }

    Note "focus and swap"
    Invoke-Ctl $state @("session", "focus", "left", "--target", $id) | Out-Null
    if ((Get-Node $state $id).splitFocused) { $failures += "focus left left the split focused" }
    $swap = Invoke-Ctl $state @("session", "swap", "--target", $id)
    if (-not $swap.ok) { $failures += "swap replied $($swap | ConvertTo-Json -Compress)" }
    if ((Get-PaneText $state $id "left") -notmatch "split-pane-ok") { $failures += "after swap the primary pane is not the split's terminal" }
    if (-not (Get-Node $state $id).splitFocused) { $failures += "focus did not follow its terminal across the swap" }

    Note "axis"
    Invoke-Ctl $state @("session", "split", "on", "--axis", "horizontal", "--target", $id) | Out-Null
    if ((Get-Node $state $id).splitAxis -ne "horizontal") { $failures += "the split did not turn top and bottom" }
    $panes = Get-Panes $window
    if ($panes.Count -eq 2 -and (Get-Rect $panes[0]).Top -eq (Get-Rect $panes[1]).Top) { $failures += "a top and bottom split's panes share a top edge" }
    Save-Snapshot $Shell "split-horizontal"

    Note "hide and close"
    Invoke-Ctl $state @("session", "split", "off", "--target", $id) | Out-Null
    $node = Get-Node $state $id
    if ($node.split -or -not $node.hasSplit) { $failures += "split off left split '$($node.split)' hasSplit '$($node.hasSplit)'" }
    if (-not (Wait-Until { (Get-Panes $window).Count -eq 1 } 5)) { $failures += "a hidden split left $((Get-Panes $window).Count) terminals visible" }
    Invoke-Ctl $state @("session", "split", "close", "--target", $id) | Out-Null
    if ((Get-Node $state $id).hasSplit) { $failures += "split close left the split" }
    $none = Invoke-Ctl $state @("session", "focus", "--target", $id)
    if ($none.error -ne "session has no split") { $failures += "focus without a split replied $($none | ConvertTo-Json -Compress)" }
    $failures
}

# the title bar's split button, the scratch's chord, and the dashboard's chord, Esc and a click on a cell
$shellCases["panes-ui"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if ([AgtermWin32]::IsZoomed($window)) { [AgtermWin32]::ShowWindow($window, 9) | Out-Null }
    $id = New-PowerShellSession $state
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
    $failures = @()
    $bar = Get-Bar $window

    Note "split button"
    Send-Click $window (Get-Centre $bar "split") $bar.Middle
    if (-not (Wait-Until { (Get-Node $state $id).split } 5)) { return @("the split button did not split the session") }
    if (-not (Wait-Until { (Get-Panes $window).Count -eq 2 } 5)) { $failures += "the split button left $((Get-Panes $window).Count) terminal(s) visible" }
    Save-Snapshot $Shell "split-button"

    Note "scratch chord"
    $terminal = Get-Panes $window | Select-Object -First 1
    [AgtermInput]::FocusOn($terminal)
    [AgtermInput]::SendChord($terminal, 0x4A, $true)
    if (-not (Wait-Until { (Get-Node $state $id).scratch } 5)) { $failures += "Ctrl+Shift+J did not show the scratch" }
    else {
        if (-not (Wait-Until { (Get-Panes $window).Count -eq 1 } 5)) { $failures += "the scratch left $((Get-Panes $window).Count) terminals visible, not itself alone" }
        if (-not (Wait-Until { (Get-PaneText $state $id "scratch") -match ">" } 30)) { $failures += "the scratch's shell never showed a prompt" }
        Save-Snapshot $Shell "scratch"
        $scratch = Get-Panes $window | Select-Object -First 1
        [AgtermInput]::FocusOn($scratch)
        [AgtermInput]::SendChord($scratch, 0x4A, $true)
        if (-not (Wait-Until { -not (Get-Node $state $id).scratch } 5)) { $failures += "a second Ctrl+Shift+J did not hide the scratch" }
        if (-not (Get-Node $state $id).scratchCwd) { $failures += "a hidden scratch's shell did not keep running" }
    }

    Note "dashboard chord"
    $terminal = Get-Panes $window | Select-Object -First 1
    [AgtermInput]::FocusOn($terminal)
    [AgtermInput]::SendChord($terminal, 0x47, $true)
    $members = Wait-Until { $m = (Invoke-Ctl $state @("tree")).result.tree.dashboardMembers; if ($m) { , $m } } 5
    if (@($members).Count -ne 2) { $failures += "Ctrl+Shift+G opened a dashboard of '$($members -join ', ')', not the split's two panes" }
    else {
        if ([AgtermWin32]::VisibleChildren($window, "Static").Count -lt 2) { $failures += "the dashboard's cells have no name strips" }
        Save-Snapshot $Shell "dashboard"
        Send-Escape $window
        if (-not (Wait-Until { -not (Invoke-Ctl $state @("tree")).result.tree.dashboardMembers } 5)) { $failures += "Esc did not close the dashboard" }
    }

    Note "dashboard click"
    Invoke-Ctl $state @("session", "focus", "left", "--target", $id) | Out-Null
    Invoke-Ctl $state @("dashboard", "--mru") | Out-Null
    $client = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetClientRect($window, [ref]$client) | Out-Null
    $sidebar = [int][Math]::Round(240 * [AgtermWin32]::GetDpiForWindow($window) / 96)
    Send-Click $window ([int]($sidebar + 0.75 * ($client.Right - $sidebar))) ([int](($bar.Height + $client.Bottom) / 2))
    if (-not (Wait-Until { -not (Invoke-Ctl $state @("tree")).result.tree.dashboardMembers } 5)) { $failures += "a click on a cell did not close the dashboard" }
    elseif (-not (Get-Node $state $id).splitFocused) { $failures += "a click on the split's cell did not focus the split" }

    Note "settings button"
    Send-Click $window (Get-Centre $bar "settings") $bar.Middle
    $settings = Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "agterm-settings") | Select-Object -First 1 } 10
    if (-not $settings) { $failures += "the settings button did not open Settings" }
    else {
        Save-Snapshot $Shell "settings-button"
        [AgtermWin32]::PostMessageW($settings, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    $failures
}

# the quick terminal: one shell for the app in its own panel, kept while hidden, toggled by its title bar button
$shellCases["quick"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    $failures = @()
    $closed = Invoke-Ctl $state @("quick", "type", "echo no")
    if ($closed.error -ne "quick terminal not open") { $failures += "quick type before a show replied $($closed | ConvertTo-Json -Compress)" }

    Note "show"
    $show = Invoke-Ctl $state @("quick", "show")
    if (-not $show.ok) { return @("quick show replied $($show | ConvertTo-Json -Compress)") }
    if (-not (Invoke-Ctl $state @("tree")).result.tree.quickVisible) { $failures += "tree does not read quickVisible after quick show" }
    $panel = Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "agterm-quick") | Select-Object -First 1 } 5
    if (-not $panel) { return $failures + "no quick terminal panel came up" }
    if (-not (Wait-Until { (Invoke-Ctl $state @("quick", "text")).result.text -match ">" } 30)) { return $failures + "the quick terminal's shell never showed a prompt" }
    Invoke-Ctl $state @("quick", "type", "echo quick-ok`r") | Out-Null
    if (-not (Wait-Until { (Invoke-Ctl $state @("quick", "text")).result.text -match "quick-ok" })) { $failures += "the quick terminal did not run what was typed" }
    Save-ScreenSnapshot $Shell "quick"

    Note "hide keeps the shell"
    Invoke-Ctl $state @("quick", "hide") | Out-Null
    if ((Invoke-Ctl $state @("tree")).result.tree.quickVisible) { $failures += "quick hide left it visible" }
    if ([AgtermWin32]::IsWindowVisible($panel)) { $failures += "quick hide left the panel on screen" }
    Invoke-Ctl $state @("quick", "show") | Out-Null
    if ((Invoke-Ctl $state @("quick", "text")).result.text -notmatch "quick-ok") { $failures += "showing again started a new shell" }

    Note "title bar button"
    $bar = Get-Bar $window
    Send-Click $window (Get-Centre $bar "quick") $bar.Middle
    if (-not (Wait-Until { -not [AgtermWin32]::IsWindowVisible($panel) } 5)) { $failures += "the quick button did not hide a shown panel" }
    Start-Sleep -Milliseconds 600
    Send-Click $window (Get-Centre $bar "quick") $bar.Middle
    if (-not (Wait-Until { [AgtermWin32]::IsWindowVisible($panel) } 5)) { $failures += "the quick button did not show the panel" }
    Invoke-Ctl $state @("quick", "hide") | Out-Null
    $failures
}

# the dashboard from a script: named panes, the most recent sessions with a fixed font, and leaving by a selection
$shellCases["dashboard"] = {
    param($Shell)
    $state = $Shell.State
    $a = New-PowerShellSession $state
    $b = New-PowerShellSession $state @("--no-select")
    if (-not $a -or -not $b) { return @("session new failed") }
    $failures = @()
    Invoke-Ctl $state @("session", "split", "--target", $a) | Out-Null
    $reply = Invoke-Ctl $state @("dashboard", $a, "$($b):right")
    if (-not $reply.ok -or "$($reply.result.text)" -notmatch "unresolved: $($b):right") { $failures += "dashboard replied $($reply | ConvertTo-Json -Compress)" }
    $tree = (Invoke-Ctl $state @("tree")).result.tree
    if ((@($tree.dashboardMembers) -join ",") -ne "$($a):left,$($a):right") { $failures += "dashboardMembers are '$($tree.dashboardMembers -join ',')'" }
    $mru = Invoke-Ctl $state @("dashboard", "--mru", "--font-size", "9")
    if (-not $mru.ok) { $failures += "dashboard --mru replied $($mru | ConvertTo-Json -Compress)" }
    $tree = (Invoke-Ctl $state @("tree")).result.tree
    if (@($tree.dashboardMembers).Count -ne 3) { $failures += "the most recent sessions made '$($tree.dashboardMembers -join ',')'" }
    if ($tree.dashboardFontSize -ne 9 -or $tree.dashboardFontMode -ne "fixed") { $failures += "font reads '$($tree.dashboardFontSize)' '$($tree.dashboardFontMode)'" }
    if (-not $tree.dashboardHighlighted) { $failures += "no cell is highlighted" }
    Save-Snapshot $Shell "dashboard-mru"
    Invoke-Ctl $state @("session", "select", "--target", $b) | Out-Null
    if ((Invoke-Ctl $state @("tree")).result.tree.dashboardMembers) { $failures += "selecting a session left the dashboard open" }
    $none = Invoke-Ctl $state @("dashboard", "--close")
    if (-not $none.ok) { $failures += "dashboard --close with none open replied $($none | ConvertTo-Json -Compress)" }
    $failures
}
