# Settings' cases: they open Settings as its menu item does, set its controls with the controls' own messages, press
# OK or Cancel, then read native.json and what the window now does. Dot-sourced by shell-cases.ps1 after
# title-bar-cases.ps1, whose AgtermWin32 helpers they use; the ids mirror SettingsWindow.Control.

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AgtermSettings {
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    // the system marshals the string of a message below WM_USER to the control's process
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, string lParam);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@

$settingsIds = @{
    theme = 101; follows = 102; darkTheme = 103; fontFamily = 104; size = 105; sizeArrows = 106
    banners = 107; sound = 108; unseenCount = 109; flash = 110
    directory = 111; customDirectory = 112; placement = 113; confirmClose = 114; rightClickPastes = 115; scrollLines = 116
    scrollArrows = 117; distribution = 118
}
# NativeMenu.Command's raw values, which the shell's command message (WM_APP + 21, Keys.swift) carries
$commandMessage = 0x8015; $newSessionCommand = 8; $settingsCommand = 19

function Get-Control([IntPtr]$Settings, [string]$Name) { [AgtermSettings]::GetDlgItem($Settings, $settingsIds[$Name]) }

function Open-Settings($Shell, [IntPtr]$Window) {
    [AgtermSettings]::PostMessageW($Window, $commandMessage, [IntPtr]$settingsCommand, [IntPtr]::Zero) | Out-Null
    Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "agterm-settings") | Select-Object -First 1 } 10
}

# Send-Notification tells Settings a control changed, as the control itself does with WM_COMMAND.
function Send-Notification([IntPtr]$Settings, [string]$Name, [int]$Code) {
    $control = Get-Control $Settings $Name
    [AgtermSettings]::SendMessageW($Settings, 0x0111, [IntPtr](($Code -shl 16) -bor $settingsIds[$Name]), $control) | Out-Null
}

function Set-Row([IntPtr]$Settings, [string]$Name, [int]$Row, [switch]$List) {
    $message = if ($List) { 0x0186 } else { 0x014E }  # LB_SETCURSEL, CB_SETCURSEL
    [AgtermSettings]::SendMessageW((Get-Control $Settings $Name), $message, [IntPtr]$Row, [IntPtr]::Zero) | Out-Null
    Send-Notification $Settings $Name 1  # LBN_SELCHANGE and CBN_SELCHANGE
}

function Set-Check([IntPtr]$Settings, [string]$Name, [bool]$On) {
    [AgtermSettings]::SendMessageW((Get-Control $Settings $Name), 0x00F1, [IntPtr][int]$On, [IntPtr]::Zero) | Out-Null  # BM_SETCHECK
    Send-Notification $Settings $Name 0  # BN_CLICKED
}

function Set-Text([IntPtr]$Settings, [string]$Name, [string]$Text) {
    [AgtermSettings]::SendMessageW((Get-Control $Settings $Name), 0x000C, [IntPtr]::Zero, $Text) | Out-Null  # WM_SETTEXT
}

function Set-Arrows([IntPtr]$Settings, [string]$Name, [int]$Value) {
    [AgtermSettings]::SendMessageW((Get-Control $Settings $Name), 0x0400 + 113, [IntPtr]::Zero, [IntPtr]$Value) | Out-Null  # UDM_SETPOS32
}

# Find-Row is a list's row holding exactly `$Text`, -1 when none does.
function Find-Row([IntPtr]$Settings, [string]$Name, [string]$Text) {
    [int][AgtermSettings]::SendMessageW((Get-Control $Settings $Name), 0x01A2, [IntPtr]-1, $Text)  # LB_FINDSTRINGEXACT
}

# Next-Tab moves to the next tab as its arrow key does, which tells Settings with TCN_SELCHANGE.
function Next-Tab([IntPtr]$Settings) {
    $tabs = [AgtermWin32]::VisibleChildren($Settings, "SysTabControl32") | Select-Object -First 1
    [AgtermSettings]::SendMessageW($tabs, 0x0100, [IntPtr]0x27, [IntPtr]::Zero) | Out-Null  # WM_KEYDOWN VK_RIGHT
    [AgtermSettings]::SendMessageW($tabs, 0x0101, [IntPtr]0x27, [IntPtr]::Zero) | Out-Null
}

# Close-Settings presses OK or Cancel and waits for the window to go.
function Close-Settings([IntPtr]$Settings, [bool]$Keep) {
    $button = if ($Keep) { 1 } else { 2 }
    [AgtermSettings]::PostMessageW($Settings, 0x0111, [IntPtr]$button, [IntPtr]::Zero) | Out-Null
    [bool](Wait-Until { -not [AgtermSettings]::IsWindow($Settings) } 10)
}

function Get-Saved([string]$State) { Get-Content (Join-Path $State "native.json") -Raw | ConvertFrom-Json }

# Settings ▸ General's choices reach native.json and what New Session and notify do; each tab shows only its own
# controls; an appearance change previews, Cancel puts it back, OK keeps it.
$shellCases["settings"] = {
    param($Shell)
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no shell window") }
    $first = New-PowerShellSession $state
    $second = New-PowerShellSession $state @("--no-select")
    if (-not $first -or -not $second) { return @("session new failed") }
    Invoke-Ctl $state @("session", "select", "--target", $first) | Out-Null

    $settings = Open-Settings $Shell $window
    if (-not $settings) { return @("Settings did not open") }
    $failures = @()
    Save-Snapshot $Shell "settings-general" $settings
    if ([AgtermSettings]::IsWindowEnabled((Get-Control $settings "customDirectory"))) { $failures += "the folder field is enabled before This folder" }
    Set-Row $settings "directory" 2
    if (-not [AgtermSettings]::IsWindowEnabled((Get-Control $settings "customDirectory"))) { $failures += "This folder left the folder field disabled" }
    Set-Text $settings "customDirectory" "C:\Windows"
    Set-Row $settings "placement" 1
    Set-Check $settings "confirmClose" $true
    Set-Check $settings "rightClickPastes" $true
    Set-Arrows $settings "scrollArrows" 7
    Next-Tab $settings
    $appearanceShown = [AgtermWin32]::IsWindowVisible((Get-Control $settings "theme"))
    $generalHidden = -not [AgtermWin32]::IsWindowVisible((Get-Control $settings "directory"))
    if (-not ($appearanceShown -and $generalHidden)) { $failures += "the Appearance tab shows theme $appearanceShown, hides General $generalHidden" }
    Save-Snapshot $Shell "settings-appearance" $settings
    Next-Tab $settings
    if (-not [AgtermWin32]::IsWindowVisible((Get-Control $settings "banners"))) { $failures += "the Notifications tab does not show its controls" }
    Save-Snapshot $Shell "settings-notifications" $settings
    Set-Check $settings "banners" $false
    if ([AgtermSettings]::IsWindowEnabled((Get-Control $settings "sound"))) { $failures += "turning banners off left the sound choice enabled" }
    if (-not (Close-Settings $settings $true)) { return $failures + @("OK did not close Settings") }

    $saved = Get-Saved $state
    $general = $saved.general
    $expected = [ordered]@{ newSessionDirectory = "custom"; newSessionCustomDirectory = "C:\Windows"; newSessionPlacement = "afterCurrent"
                            confirmCloseSession = $true; rightClickPastes = $true; scrollLines = 7 }
    foreach ($key in $expected.Keys) {
        if ($general.$key -ne $expected[$key]) { $failures += "native.json general.$key is '$($general.$key)', not '$($expected[$key])'" }
    }
    if ($saved.notifications.banners -ne $false) { $failures += "native.json keeps banners '$($saved.notifications.banners)'" }

    [AgtermSettings]::PostMessageW($window, $commandMessage, [IntPtr]$newSessionCommand, [IntPtr]::Zero) | Out-Null
    $order = Wait-Until { $ids = @((Get-SessionNodes $state).id); if ($ids.Count -eq 3) { , $ids } } 15
    if (-not $order) {
        $failures += "New Session did not add a session"
    } else {
        $added = $order[1]
        if ($order[0] -ne $first -or $order[2] -ne $second) { $failures += "New Session did not land after the selected session: $($order -join ', ')" }
        elseif (-not (Wait-Until { (Get-Node $state $added).cwd -eq "C:\Windows" } 30)) { $failures += "New Session started in '$((Get-Node $state $added).cwd)'" }
    }
    $note = Invoke-Ctl $state @("notify", "--target", $second, "built")
    if ("$($note.result.text)" -notmatch "is off") { $failures += "notify with banners off replied $($note | ConvertTo-Json -Compress)" }

    $settings = Open-Settings $Shell $window
    if (-not $settings) { return $failures + @("Settings did not open again") }
    $dracula = Find-Row $settings "theme" "Dracula"
    if ($dracula -lt 0) { return $failures + @("the theme list lacks Dracula") }
    Set-Row $settings "theme" $dracula -List
    Start-Sleep -Milliseconds 500
    Save-Snapshot $Shell "settings-preview"
    Close-Settings $settings $false | Out-Null
    if ((Invoke-Ctl $state @("theme", "list")).result.theme -or (Get-Saved $state).appearance.theme) { $failures += "Cancel kept the previewed theme" }
    $settings = Open-Settings $Shell $window
    Set-Row $settings "theme" (Find-Row $settings "theme" "Dracula") -List
    Close-Settings $settings $true | Out-Null
    if ((Invoke-Ctl $state @("theme", "list")).result.theme -ne "Dracula") { $failures += "OK did not keep Dracula" }
    Save-Snapshot $Shell "settings-kept"
    $failures
}
