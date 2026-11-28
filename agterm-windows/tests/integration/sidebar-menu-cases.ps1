# The sidebar rows' context menus, opened at a row as a right click opens them. Dot-sourced by shell-cases.ps1 after
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
