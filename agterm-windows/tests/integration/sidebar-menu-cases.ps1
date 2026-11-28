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
        Remove-Item -Recurse -Force $parent
        $reply = Invoke-Ctl $state @("session", "reveal", "--target", $id)
        if ($reply.ok -or $reply.error -ne "session cwd is not an existing directory") { $failures += "session reveal on a removed folder answered $($reply | ConvertTo-Json -Compress)" }
        $failures
    } finally { Remove-Item -Recurse -Force $parent -ErrorAction SilentlyContinue }
}
