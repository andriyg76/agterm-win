# The sidebar rows' context menus, opened at a row as a right click opens them, and what their items do. Dot-sourced by shell-cases.ps1 after
# title-bar-cases.ps1, whose AgtermWin32 helpers it uses.

# Open-RowMenu opens the context menu of the sidebar's `Row`-th row from the top and returns the menu window.
function Open-RowMenu($Shell, [IntPtr]$Window, [int]$Row) {
    $tree = [AgtermWin32]::VisibleChildren($Window, "SysTreeView32") | Select-Object -First 1
    if (-not $tree) { return $null }
    $height = [int][AgtermWin32]::SendMessageW($tree, 0x111C, [IntPtr]::Zero, [IntPtr]::Zero)   # TVM_GETITEMHEIGHT
    $point = Get-ScreenPoint $tree 40 ([int](($Row + 0.5) * $height))
    [AgtermWin32]::PostMessageW($Window, 0x007B, $tree, [AgtermWin32]::At($point.X, $point.Y)) | Out-Null
    Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "#32768") | Select-Object -First 1 } 5
}

# Choose-MenuItem clicks the item titled `Title` and waits for the menu to close; false when the menu has no such item.
function Choose-MenuItem($Shell, [IntPtr]$Menu, [string]$Title) {
    $position = [AgtermWin32]::MenuPosition($Menu, $Title)
    if ($position -lt 0) { Send-Escape $Menu; return $false }
    $clicked = Click-MenuItem $Menu ([uint32]$position)
    Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "#32768").Count -eq 0 } 5 | Out-Null
    $clicked
}

# Read-Clipboard is the clipboard's text, null while another process holds it open.
function Read-Clipboard { try { Get-Clipboard -Raw -ErrorAction Stop } catch { $null } }

# Copy Name puts a session's and a workspace's name on the clipboard, not the terminal's selection
$shellCases["copy-name"] = {
    param($Shell)
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $id = New-PowerShellSession $state
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
    Get-SessionNodes $state | ? { $_.id -ne $id } | % { Invoke-Ctl $state @("session", "close", "--target", $_.id) | Out-Null }
    Invoke-Ctl $state @("session", "rename", "Build Box", "--target", $id) | Out-Null
    Invoke-Ctl $state @("workspace", "new", "Release Notes") | Out-Null
    if (-not (Wait-Until { @(Get-SessionNodes $state).Count -eq 1 -and (Get-Node $state $id).name -eq "Build Box" } 10)) {
        return @("the window did not settle on one session named Build Box")
    }
    $failures = @()
    Invoke-Ctl $state @("session", "selectall", "--target", $id) | Out-Null
    Set-Clipboard -Value "before"

    Note "session row"
    $menu = Open-RowMenu $Shell $window 0
    if (-not $menu) { return @("a right click on the session row opened no menu") }
    if ([AgtermWin32]::MenuTitles($menu) -notcontains "Rename Session") { $failures += "row 0 is not the session: $([AgtermWin32]::MenuTitles($menu) -join ',')" }
    if (-not (Choose-MenuItem $Shell $menu "Copy Name")) { return $failures + "the session row's menu has no Copy Name" }
    if (-not (Wait-Until { (Read-Clipboard) -ceq "Build Box" } 5)) { $failures += "the clipboard holds '$(Read-Clipboard)', not the session's name" }

    Note "workspace row"
    $menu = Open-RowMenu $Shell $window 1
    if (-not $menu) { return $failures + "a right click on the workspace row opened no menu" }
    if ([AgtermWin32]::MenuTitles($menu) -notcontains "Rename Workspace") { $failures += "row 1 is not the workspace: $([AgtermWin32]::MenuTitles($menu) -join ',')" }
    if (-not (Choose-MenuItem $Shell $menu "Copy Name")) { return $failures + "the workspace row's menu has no Copy Name" }
    if (-not (Wait-Until { (Read-Clipboard) -ceq "Release Notes" } 5)) { $failures += "the clipboard holds '$(Read-Clipboard)', not the workspace's name" }
    $failures
}

# Get-FolderWindows is every Explorer folder window on the desktop, whichever explorer.exe process draws it.
function Get-FolderWindows { @(Get-Process explorer -ErrorAction SilentlyContinue | % { [AgtermWin32]::Visible($_.Id, "CabinetWClass") }) }

# Wait-NewFolderWindow waits for a folder window that was not in `Before`, titled `Title`, and closes it.
function Wait-NewFolderWindow($Before, [string]$Title) {
    $opened = Wait-Until { Get-FolderWindows | ? { $Before -notcontains $_ -and [AgtermWin32]::TextOf($_) -like "$Title*" } | Select-Object -First 1 } 15
    if ($opened) { [AgtermWin32]::PostMessageW($opened, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }   # WM_CLOSE
    [bool]$opened
}

# Reveal in Explorer opens the session's folder in its parent, from the row menu and session.reveal; a folder that
# is gone is refused
$shellCases["reveal-explorer"] = {
    param($Shell)
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $parent = Join-Path $env:TEMP "agterm-reveal-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $dir = Join-Path $parent "work"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        $id = New-PowerShellSession $state @("--cwd", $dir)
        if (-not $id -or -not (Wait-Until { (Get-Node $state $id).cwd -eq $dir } 30)) { return @("the session never reported $dir") }
        Get-SessionNodes $state | ? { $_.id -ne $id } | % { Invoke-Ctl $state @("session", "close", "--target", $_.id) | Out-Null }
        if (-not (Wait-Until { @(Get-SessionNodes $state).Count -eq 1 } 10)) { return @("the other sessions did not close") }
        $failures = @()
        $leaf = Split-Path $parent -Leaf
        # without the foreground, the folder window opens behind and is closed, but not required
        $script:InFront = Bring-Front $window

        Note "session.reveal"
        $before = Get-FolderWindows
        $reply = Invoke-Ctl $state @("session", "reveal", "--target", $id)
        if (-not $reply.ok) { $failures += "session reveal refused an existing folder: $($reply.error)" }
        elseif (-not (Wait-NewFolderWindow $before $leaf) -and $script:InFront) { $failures += "session reveal opened no Explorer window on $leaf" }

        Note "row menu"
        $script:InFront = Bring-Front $window
        $before = Get-FolderWindows
        $menu = Open-RowMenu $Shell $window 0
        if (-not $menu) { return $failures + "a right click on the session row opened no menu" }
        if (-not (Choose-MenuItem $Shell $menu "Reveal in Explorer")) { return $failures + "the session row's menu has no Reveal in Explorer" }
        if (-not (Wait-NewFolderWindow $before $leaf) -and $script:InFront) { $failures += "Reveal in Explorer opened no Explorer window on $leaf" }

        Note "a folder that is gone"
        # the shell holds its folder; the session keeps the folder it last reported once the shell exits
        Invoke-Ctl $state @("session", "type", "exit`r", "--target", $id) | Out-Null
        if (-not (Wait-Until { Remove-Item -Recurse -Force $parent -ErrorAction SilentlyContinue; -not (Test-Path $parent) } 15)) {
            return $failures + "$parent could not be removed after the shell exited"
        }
        $reply = Invoke-Ctl $state @("session", "reveal", "--target", $id)
        if ($reply.ok -or $reply.error -ne "session cwd is not an existing directory") { $failures += "session reveal on a removed folder answered $($reply | ConvertTo-Json -Compress)" }
        $failures
    } finally { Remove-Item -Recurse -Force $parent -ErrorAction SilentlyContinue }
}

# Get-Folds is each named workspace's `collapsed`, by name.
function Get-Folds([string]$State) {
    $folds = @{}
    (Invoke-Ctl $State @("tree")).result.tree.workspaces | ? { $_.name } | % { $folds[$_.name] = [bool]$_.collapsed }
    $folds
}

# Expand Workspaces opens every workspace and Collapse Workspaces folds all but the current one, from View and
# sidebar.expand/collapse; a workspace row's fold item is titled for what it does
$shellCases["workspace-folds"] = {
    param($Shell)
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $dev = (Invoke-Ctl $state @("workspace", "new", "dev", "--collapsed")).result.id
    $ops = (Invoke-Ctl $state @("workspace", "new", "ops", "--collapsed")).result.id
    if (-not $dev -or -not $ops) { return @("workspace new did not create dev and ops") }
    $id = New-PowerShellSession $state @("--workspace", $dev)
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
    Get-SessionNodes $state | ? { $_.id -ne $id } | % { Invoke-Ctl $state @("session", "close", "--target", $_.id) | Out-Null }
    if (-not (Wait-Until { @(Get-SessionNodes $state).Count -eq 1 } 10)) { return @("the other sessions did not close") }
    $failures = @()

    Note "sidebar expand and collapse"
    Invoke-Ctl $state @("sidebar", "expand") | Out-Null
    $folds = Get-Folds $state
    if ($folds.dev -or $folds.ops) { $failures += "sidebar expand left dev collapsed=$($folds.dev), ops collapsed=$($folds.ops)" }
    Invoke-Ctl $state @("sidebar", "collapse") | Out-Null
    $folds = Get-Folds $state
    if ($folds.dev -or -not $folds.ops) { $failures += "sidebar collapse gave dev collapsed=$($folds.dev), ops collapsed=$($folds.ops)" }

    # rows top down: dev, its session, ops
    Note "workspace row"
    $menu = Open-RowMenu $Shell $window 2
    if (-not $menu) { return $failures + "a right click on the ops row opened no menu" }
    if ([AgtermWin32]::MenuTitles($menu) -notcontains "Rename Workspace") { $failures += "row 2 is not a workspace: $([AgtermWin32]::MenuTitles($menu) -join ',')" }
    if (-not (Choose-MenuItem $Shell $menu "Expand Workspace")) { return $failures + "the folded ops row's menu has no Expand Workspace" }
    if (-not (Wait-Until { -not (Get-Folds $state).ops } 5)) { $failures += "Expand Workspace left ops folded" }

    Note "View menu"
    $sidebarPts = (Invoke-Ctl $state @("tree")).result.tree.sidebarWidth
    $bar = Get-Bar $window $(if ($sidebarPts) { $sidebarPts } else { 220 })
    Send-Click $window (Get-Centre $bar "view") $bar.MenuMiddle
    $menu = Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "#32768") | Select-Object -First 1 } 5
    if (-not $menu) { return $failures + "View opened no menu" }
    if ([AgtermWin32]::MenuTitles($menu) -notcontains "Collapse Workspace") { $failures += "View does not offer the open dev's Collapse Workspace" }
    if (-not (Choose-MenuItem $Shell $menu "Collapse Workspaces")) { return $failures + "View has no Collapse Workspaces" }
    if (-not (Wait-Until { $f = Get-Folds $state; $f.ops -and -not $f.dev } 5)) { $failures += "Collapse Workspaces did not fold ops alone" }
    $failures
}

# Open-Submenu opens the item titled `Title` of an open menu and returns the submenu's window.
function Open-Submenu($Shell, [IntPtr]$Menu, [string]$Title) {
    $before = @([AgtermWin32]::Visible($Shell.Process.Id, "#32768"))
    $position = [AgtermWin32]::MenuPosition($Menu, $Title)
    if ($position -lt 0 -or -not (Click-MenuItem $Menu ([uint32]$position))) { return $null }
    Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "#32768") | ? { $before -notcontains $_ } | Select-Object -First 1 } 5
}

# Choose-Tint picks Tint > `Title` on the `Row`-th row's menu.
function Choose-Tint($Shell, [IntPtr]$Window, [int]$Row, [string]$Title) {
    $menu = Open-RowMenu $Shell $Window $Row
    if (-not $menu) { return $false }
    $tint = Open-Submenu $Shell $menu "Tint"
    if (-not $tint) { Send-Escape $menu; return $false }
    Choose-MenuItem $Shell $tint $Title
}

# Get-TealSpan is how wide the teal pixels (macOS teal, light or dark) of the sidebar's `Row`-th row spread, 0 with none.
function Get-TealSpan($Shell, [IntPtr]$Window, [int]$Row) {
    $tree = [AgtermWin32]::VisibleChildren($Window, "SysTreeView32") | Select-Object -First 1
    $height = [int][AgtermWin32]::SendMessageW($tree, 0x111C, [IntPtr]::Zero, [IntPtr]::Zero)
    $rect = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetClientRect($tree, [ref]$rect) | Out-Null
    $origin = Get-ScreenPoint $tree 0 0
    $client = Get-ScreenPoint $Window 0 0
    $shot = Get-Shot $Window
    $left = $null
    $right = $null
    for ($x = 0; $x -lt $rect.Right; $x++) {
        for ($y = $Row * $height; $y -lt ($Row + 1) * $height; $y++) {
            $c = $shot.Bitmap.GetPixel($origin.X - $client.X + $x + $shot.X, $origin.Y - $client.Y + $y + $shot.Y)
            $light = [Math]::Abs($c.R - 0x30) + [Math]::Abs($c.G - 0xB0) + [Math]::Abs($c.B - 0xC7)
            $dark = [Math]::Abs($c.R - 0x40) + [Math]::Abs($c.G - 0xC8) + [Math]::Abs($c.B - 0xE0)
            if ([Math]::Min($light, $dark) -le 24) {
                if ($null -eq $left) { $left = $x }
                $right = $x
            }
        }
    }
    $shot.Bitmap.Dispose()
    if ($null -eq $left) { 0 } else { $right - $left + 1 }
}

# Tint from the row menus colors a session's dot, then its name, a workspace starting on the last Show On pick, and
# None clears it; the tree reads each back and session.tint's hex shows as the menu's checked Custom entry
$shellCases["sidebar-tint"] = {
    param($Shell)
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $id = New-PowerShellSession $state
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session never reached its prompt") }
    Get-SessionNodes $state | ? { $_.id -ne $id } | % { Invoke-Ctl $state @("session", "close", "--target", $_.id) | Out-Null }
    $workspace = (Invoke-Ctl $state @("workspace", "new", "Tinted")).result.id
    if (-not (Wait-Until { @(Get-SessionNodes $state).Count -eq 1 } 10)) { return @("the window did not settle on one session") }
    $failures = @()
    if ((Get-TealSpan $Shell $window 0) -ne 0) { $failures += "an untinted row already shows teal" }

    Note "Tint > Teal starts on the icon"
    if (-not (Choose-Tint $Shell $window 0 "Teal")) { return $failures + "the session row's menu has no Tint > Teal" }
    if (-not (Wait-Until { $n = Get-Node $state $id; $n.tint -eq "teal" -and ($n.tintOn -join ",") -eq "icon" } 5)) {
        $n = Get-Node $state $id
        return $failures + "the session reads back tint '$($n.tint)' on '$($n.tintOn -join ",")', not teal on icon"
    }
    $dot = Wait-Until { $s = Get-TealSpan $Shell $window 0; if ($s -gt 0) { $s } } 5
    if (-not $dot) { $failures += "no teal dot was drawn on the row" }
    Save-ScreenSnapshot $Shell "tint-icon"

    Note "Show On > Name"
    if (-not (Choose-Tint $Shell $window 0 "Name")) { return $failures + "the Tint submenu has no Name" }
    if (-not (Wait-Until { ((Get-Node $state $id).tintOn -join ",") -eq "name" } 5)) { $failures += "Show On > Name did not move the tint to the name" }
    $name = Wait-Until { $s = Get-TealSpan $Shell $window 0; if ($s -gt 2 * $dot) { $s } } 5
    if (-not $name) { $failures += "the teal name is no wider than the dot ($(Get-TealSpan $Shell $window 0) px vs $dot)" }
    Save-ScreenSnapshot $Shell "tint-name"

    Note "a workspace starts on the last Show On pick"
    if (-not (Choose-Tint $Shell $window 1 "Orange")) { return $failures + "the workspace row's menu has no Tint > Orange" }
    $tinted = Wait-Until { (Invoke-Ctl $state @("tree")).result.tree.workspaces | ? { $_.id -eq $workspace -and $_.tint -eq "orange" } } 5
    if (-not $tinted) { $failures += "the workspace did not read back orange" }
    elseif (($tinted.tintOn -join ",") -ne "name") { $failures += "the workspace started on '$($tinted.tintOn -join ",")', not the last pick, name" }

    Note "None clears"
    if (-not (Choose-Tint $Shell $window 0 "None")) { return $failures + "the Tint submenu has no None" }
    if (-not (Wait-Until { -not (Get-Node $state $id).tint } 5)) { $failures += "None left the session tinted" }
    if (-not (Wait-Until { (Get-TealSpan $Shell $window 0) -eq 0 } 5)) { $failures += "a cleared row still shows teal" }

    Note "a hex from session.tint"
    Invoke-Ctl $state @("session", "tint", "#123abc", "--target", $id) | Out-Null
    if (-not (Wait-Until { (Get-Node $state $id).tint -eq "#123abc" } 5)) { $failures += "session tint set #123abc did not read back" }
    $menu = Open-RowMenu $Shell $window 0
    $tint = if ($menu) { Open-Submenu $Shell $menu "Tint" }
    if (-not $tint) { $failures += "the Tint submenu did not open" }
    elseif ([AgtermWin32]::MenuTitles($tint) -notcontains "Custom #123abc") { $failures += "the submenu lists $([AgtermWin32]::MenuTitles($tint) -join ',')" }
    if ($tint) { Send-Escape $tint }
    if ($menu) { Send-Escape $menu }
    $failures
}
