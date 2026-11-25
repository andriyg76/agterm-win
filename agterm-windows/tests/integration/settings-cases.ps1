# Settings' cases: they open Settings with `settings open` or as its menu item does, set its controls with the controls' own messages, press
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
    scrollArrows = 117
}
# NativeMenu.Command's raw values, which the shell's command message (WM_APP + 21, Keys.swift) carries
$commandMessage = 0x8015; $newSessionCommand = 8; $settingsCommand = 19

function Get-Control([IntPtr]$Settings, [string]$Name) { [AgtermSettings]::GetDlgItem($Settings, $settingsIds[$Name]) }

# Open-Settings opens Settings on `$Tab` with `settings open`, or without one as the menu item does.
function Open-Settings($Shell, [IntPtr]$Window, [string]$Tab) {
    if ($Tab) {
        $reply = Invoke-Ctl $Shell.State @("settings", "open", $Tab)
        if ($reply.result.text -ne $Tab) { Write-Host "  settings open $Tab replied $($reply | ConvertTo-Json -Compress)"; return $null }
    } else {
        [AgtermSettings]::PostMessageW($Window, $commandMessage, [IntPtr]$settingsCommand, [IntPtr]::Zero) | Out-Null
    }
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

function Find-ComboRow([IntPtr]$Settings, [string]$Name, [string]$Text) {
    [int][AgtermSettings]::SendMessageW((Get-Control $Settings $Name), 0x0158, [IntPtr]-1, $Text)  # CB_FINDSTRINGEXACT
}

# Get-TerminalBackground is the colour of the shown terminal near its bottom right, where a short session prints
# nothing, as rrggbb.
function Get-TerminalBackground([IntPtr]$Window) {
    $shot = Get-Shot $Window
    try {
        $client = New-Object AgtermWin32+Rect
        [AgtermWin32]::GetClientRect($Window, [ref]$client) | Out-Null
        $c = $shot.Bitmap.GetPixel($shot.X + $client.Right - 40, $shot.Y + $client.Bottom - 20)
        "{0:x2}{1:x2}{2:x2}" -f $c.R, $c.G, $c.B
    } finally { $shot.Bitmap.Dispose() }
}

function Test-Colour([string]$Actual, [string]$Expected) {
    if ($Actual.Length -ne 6) { return $false }
    foreach ($i in 0, 2, 4) {
        if ([Math]::Abs([Convert]::ToInt32($Actual.Substring($i, 2), 16) - [Convert]::ToInt32($Expected.Substring($i, 2), 16)) -gt 2) { return $false }
    }
    $true
}

# Get-ControlColour is the colour Settings draws `$Dx`, `$Dy` pixels into one of its controls, as rrggbb.
function Get-ControlColour([IntPtr]$Settings, [IntPtr]$Control, [int]$Dx, [int]$Dy) {
    $shot = Get-Shot $Settings
    try {
        $window = New-Object AgtermWin32+Rect
        [AgtermWin32]::GetWindowRect($Settings, [ref]$window) | Out-Null
        $rect = New-Object AgtermWin32+Rect
        [AgtermWin32]::GetWindowRect($Control, [ref]$rect) | Out-Null
        $c = $shot.Bitmap.GetPixel($rect.Left - $window.Left + $Dx, $rect.Top - $window.Top + $Dy)
        "{0:x2}{1:x2}{2:x2}" -f $c.R, $c.G, $c.B
    } finally { $shot.Bitmap.Dispose() }
}

# Test-SettingsChrome checks Settings is drawn in the chrome palette: its tab page in `$Page`, and with `-Dark` the OK
# button and the folder field dark too, where Windows draws its own controls light.
function Test-SettingsChrome([IntPtr]$Settings, [string]$Page, [string]$Label, [switch]$Dark) {
    $tabs = [AgtermWin32]::VisibleChildren($Settings, "SysTabControl32") | Select-Object -First 1
    $colour = Get-ControlColour $Settings $tabs 6 40
    if (-not (Test-Colour $colour $Page)) { "with $Label Settings' page is #$colour, not #$Page" }
    if (-not $Dark) { return }
    foreach ($control in @(@("OK", [AgtermSettings]::GetDlgItem($Settings, 1)), @("the folder field", (Get-Control $Settings "customDirectory")))) {
        $rect = New-Object AgtermWin32+Rect
        [AgtermWin32]::GetWindowRect($control[1], [ref]$rect) | Out-Null
        $colour = Get-ControlColour $Settings $control[1] 4 (($rect.Bottom - $rect.Top) / 2)
        $level = ([Convert]::ToInt32($colour.Substring(0, 2), 16) + [Convert]::ToInt32($colour.Substring(2, 2), 16) + [Convert]::ToInt32($colour.Substring(4, 2), 16)) / 3
        if ($level -gt 0x60) { "with $Label $($control[0]) is drawn #$colour" }
    }
}

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
    # ChromePalette's title bar color: the default background, #0c0c0c, 42% toward black
    $failures += @(Test-SettingsChrome $settings "070707" "the default theme" -Dark)
    if ([AgtermSettings]::IsWindowEnabled((Get-Control $settings "customDirectory"))) { $failures += "the folder field is enabled before This folder" }
    Set-Row $settings "directory" 2
    if (-not [AgtermSettings]::IsWindowEnabled((Get-Control $settings "customDirectory"))) { $failures += "This folder left the folder field disabled" }
    Set-Text $settings "customDirectory" "C:\Windows"
    Set-Row $settings "placement" 1
    Set-Check $settings "confirmClose" $true
    Set-Check $settings "rightClickPastes" $true
    Set-Arrows $settings "scrollArrows" 7
    Next-Tab $settings
    $consolas = Find-ComboRow $settings "fontFamily" "Consolas"
    if ($consolas -lt 0) { $failures += "the font list lacks Consolas" } else { Set-Row $settings "fontFamily" $consolas }
    Set-Arrows $settings "sizeArrows" 14
    Send-Notification $settings "size" 0x0300  # EN_CHANGE
    $appearanceShown = [AgtermWin32]::IsWindowVisible((Get-Control $settings "theme"))
    $generalHidden = -not [AgtermWin32]::IsWindowVisible((Get-Control $settings "directory"))
    if (-not ($appearanceShown -and $generalHidden)) { $failures += "the Appearance tab shows theme $appearanceShown, hides General $generalHidden" }
    Save-Snapshot $Shell "settings-appearance" $settings
    if ((Open-Settings $Shell $window "notifications") -ne $settings) { $failures += "settings open on an open Settings opened another window" }
    if (-not [AgtermWin32]::IsWindowVisible((Get-Control $settings "banners"))) { $failures += "settings open notifications did not show that tab" }
    if ([AgtermWin32]::IsWindowVisible((Get-Control $settings "theme"))) { $failures += "settings open notifications left the Appearance tab shown" }
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
    if ($saved.appearance.fontFamily -ne "Consolas" -or $saved.fontPoints -ne 14) {
        $failures += "native.json keeps font '$($saved.appearance.fontFamily)' at $($saved.fontPoints)"
    }
    $sizes = @((Get-SessionNodes $state).fontSize | Select-Object -Unique)
    if ($sizes.Count -ne 1 -or $sizes[0] -ne 14) { $failures += "tree reports font sizes $($sizes -join ', ')" }

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

    $settings = Open-Settings $Shell $window "appearance"
    if (-not $settings) { return $failures + @("settings open appearance did not open Settings") }
    if (-not [AgtermWin32]::IsWindowVisible((Get-Control $settings "theme"))) { $failures += "settings open appearance did not show that tab" }
    $dracula = Find-Row $settings "theme" "Dracula"
    if ($dracula -lt 0) { return $failures + @("the theme list lacks Dracula") }
    Set-Row $settings "theme" $dracula -List
    Start-Sleep -Milliseconds 500
    Save-Snapshot $Shell "settings-preview"
    # the preview recolors Settings too: Dracula's #282a36 42% toward black
    $failures += @(Test-SettingsChrome $settings "17181f" "Dracula previewed")
    Close-Settings $settings $false | Out-Null
    if ((Invoke-Ctl $state @("theme", "list")).result.theme -or (Get-Saved $state).appearance.theme) { $failures += "Cancel kept the previewed theme" }
    $settings = Open-Settings $Shell $window "appearance"
    Set-Row $settings "theme" (Find-Row $settings "theme" "Dracula") -List
    Close-Settings $settings $true | Out-Null
    if ((Invoke-Ctl $state @("theme", "list")).result.theme -ne "Dracula") { $failures += "OK did not keep Dracula" }
    $background = Get-TerminalBackground $window
    if (-not (Test-Colour $background "282a36")) { $failures += "with Dracula kept the terminal is #$background, not #282a36" }
    Save-Snapshot $Shell "settings-kept"
    $failures
}

$personalize = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

# Set-AppMode switches Windows' app mode and tells the window, as Windows does with WM_SETTINGCHANGE.
function Set-AppMode([IntPtr]$Window, [bool]$Light) {
    Set-ItemProperty $personalize -Name AppsUseLightTheme -Value ([int]$Light) -Type DWord
    [AgtermSettings]::SendMessageW($Window, 0x001A, [IntPtr]::Zero, "ImmersiveColorSet") | Out-Null
}

# With Follow Windows light and dark mode on, the dark theme draws while Windows is dark and the light one while it is
# light. It changes the desktop's app mode, so it runs on CI's runner only, putting the mode back after.
# settings open refuses a tab Settings does not have
$shellCases["settings-open"] = {
    param($Shell)
    $reply = Invoke-Ctl $Shell.State @("settings", "open", "keys")
    if ($reply.ok) { return @("settings open keys replied $($reply | ConvertTo-Json -Compress)") }
    if ([AgtermWin32]::Visible($Shell.Process.Id, "agterm-settings")) { @("a refused tab opened Settings") }
}

$shellCases["settings-system-theme"] = {
    param($Shell)
    if ($env:GITHUB_ACTIONS -ne "true") {
        Note "skipped: it switches Windows' app mode, which only CI's runner may have changed"
        return @()
    }
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no shell window") }
    $id = New-PowerShellSession $state
    if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the session did not start") }
    $before = (Get-ItemProperty $personalize -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
    $failures = @()
    try {
        Set-AppMode $window $true
        $settings = Open-Settings $Shell $window "appearance"
        if (-not $settings) { return @("Settings did not open") }
        Set-Row $settings "theme" (Find-Row $settings "theme" "Dracula") -List
        Set-Check $settings "follows" $true
        if (-not [AgtermSettings]::IsWindowEnabled((Get-Control $settings "darkTheme"))) { $failures += "following left the dark theme list disabled" }
        Set-Row $settings "darkTheme" (Find-Row $settings "darkTheme" "Nord") -List
        Close-Settings $settings $true | Out-Null
        $list = (Invoke-Ctl $state @("theme", "list")).result
        if (-not $list.sync -or $list.light -ne "Dracula" -or $list.dark -ne "Nord" -or $list.theme -ne "Dracula") {
            $failures += "in light mode theme list is $($list | Select-Object theme, light, dark, sync | ConvertTo-Json -Compress)"
        }
        $light = Get-TerminalBackground $window
        if (-not (Test-Colour $light "282a36")) { $failures += "in light mode the terminal is #$light, not Dracula's #282a36" }
        Save-Snapshot $Shell "system-light"
        Set-AppMode $window $false
        if (-not (Wait-Until { (Invoke-Ctl $state @("theme", "list")).result.theme -eq "Nord" } 10)) { $failures += "dark mode did not make Nord the theme" }
        Start-Sleep -Milliseconds 500
        $dark = Get-TerminalBackground $window
        if (-not (Test-Colour $dark "2e3440")) { $failures += "in dark mode the terminal is #$dark, not Nord's #2e3440" }
        Save-Snapshot $Shell "system-dark"
    } finally {
        if ($null -ne $before) { Set-AppMode $window ([bool]$before) } else { Remove-ItemProperty $personalize -Name AppsUseLightTheme -ErrorAction SilentlyContinue }
    }
    $failures
}
