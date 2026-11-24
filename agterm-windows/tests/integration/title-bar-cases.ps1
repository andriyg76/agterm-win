# The title bar's cases: they send the window the messages Windows sends it (hit tests, clicks, presses on the
# frame's buttons), read the outcome back through Win32 and agtermctl, and check the pixels the bar painted.
# Dot-sourced by shell-cases.ps1 after its helpers; the geometry mirrors TitleBar.swift.

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class AgtermWin32 {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    public delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr menu, int position);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    public static string ClassOf(IntPtr window) {
        var name = new StringBuilder(256);
        GetClassNameW(window, name, name.Capacity);
        return name.ToString();
    }

    public static string TextOf(IntPtr window) {
        var text = new StringBuilder(1024);
        GetWindowTextW(window, text, text.Capacity);
        return text.ToString();
    }

    // Visible is the process's visible top-level windows of a class: its main window, a menu (#32768), a dialog (#32770).
    public static IntPtr[] Visible(int pid, string className) {
        var found = new List<IntPtr>();
        EnumProc each = delegate(IntPtr window, IntPtr data) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == pid && IsWindowVisible(window) && ClassOf(window) == className) found.Add(window);
            return true;
        };
        EnumWindows(each, IntPtr.Zero);
        return found.ToArray();
    }

    public static IntPtr[] VisibleChildren(IntPtr parent, string className) {
        var found = new List<IntPtr>();
        EnumProc each = delegate(IntPtr window, IntPtr data) {
            if (IsWindowVisible(window) && ClassOf(window) == className) found.Add(window);
            return true;
        };
        EnumChildWindows(parent, each, IntPtr.Zero);
        return found.ToArray();
    }

    public static IntPtr At(int x, int y) { return (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF)); }

    // MenuIds reads the items of a shown popup menu through MN_GETHMENU; a submenu's id is 0xFFFFFFFF.
    public static uint[] MenuIds(IntPtr menuWindow) {
        IntPtr menu = SendMessageW(menuWindow, 0x01E1, IntPtr.Zero, IntPtr.Zero);
        var ids = new List<uint>();
        int count = GetMenuItemCount(menu);
        for (int i = 0; i < count; i++) ids.Add(GetMenuItemID(menu, i));
        return ids.ToArray();
    }
}
'@

$hitClient = 1; $hitCaption = 2; $hitTop = 12; $hitMinimize = 8; $hitMaximize = 9; $hitClose = 20

function Get-ShellWindow($Shell) {
    Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "agterm-shell") | Select-Object -First 1 } 10
}

# Get-Bar is TitleBar's layout at the window's size and dpi: each part's horizontal centre, in client pixels.
function Get-Bar([IntPtr]$Window, [double]$SidebarWidthPts = 220) {
    $dpi = [AgtermWin32]::GetDpiForWindow($Window)
    $scaled = { param($v) [int][Math]::Floor(($v * $dpi + 48) / 96) }
    $client = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetClientRect($Window, [ref]$client) | Out-Null
    $width = $client.Right; $action = & $scaled 40; $caption = & $scaled 46; $height = & $scaled 40
    $sidebar = [int][Math]::Round($SidebarWidthPts * $dpi / 96)
    $menuStart = $sidebar + $action + [Math]::Floor($action / 4)
    $labelW = { param($t) & $scaled ($t.Length * 7 + 20) }
    $menuGap = [Math]::Max(1, [Math]::Floor((& $scaled 7) / 5))
    $menuLimit = $width - 3 * $caption - 5 * $action - [Math]::Floor($action / 4)
    $x = $menuStart; $menuEnd = $menuStart
    $menuSpans = [ordered]@{}
    foreach ($pair in @(@("file", "File"), @("view", "View"), @("navigate", "Navigate"), @("help", "Help"))) {
        $w = & $labelW $pair[1]
        if (($x + $w) -gt $menuLimit) { break }
        $menuSpans[$pair[0]] = @($x, ($x + $w)); $x += $w + $menuGap; $menuEnd = $x - $menuGap
    }
    $titleLeft = [Math]::Max(($sidebar + $action), $menuEnd) + [Math]::Floor($action / 4)
    $titleRight = $width - 3 * $caption - 5 * $action - [Math]::Floor($action / 4)
    $spans = [ordered]@{ "new session" = @($sidebar, ($sidebar + $action)) }
    foreach ($key in $menuSpans.Keys) { $spans[$key] = $menuSpans[$key] }
    $spans.quick = @(($width - 3 * $caption - 5 * $action), ($width - 3 * $caption - 4 * $action))
    $spans.split = @(($width - 3 * $caption - 4 * $action), ($width - 3 * $caption - 3 * $action))
    $spans.dashboard = @(($width - 3 * $caption - 3 * $action), ($width - 3 * $caption - 2 * $action))
    $spans.find = @(($width - 3 * $caption - 2 * $action), ($width - 3 * $caption - $action))
    $spans.settings = @(($width - 3 * $caption - $action), ($width - 3 * $caption))
    $spans.minimize = @(($width - 3 * $caption), ($width - 2 * $caption))
    $spans.maximize = @(($width - 2 * $caption), ($width - $caption))
    $spans.close = @(($width - $caption), $width)
    [pscustomobject]@{ Height = $height; Width = $width; Action = $action; Caption = $caption; Middle = [int]($height / 2)
                       Spans = $spans; Title = @($titleLeft, $titleRight) }
}

function Get-Centre($Bar, [string]$Part) { [int](($Bar.Spans[$Part][0] + $Bar.Spans[$Part][1]) / 2) }

function Get-ScreenPoint([IntPtr]$Window, [int]$X, [int]$Y) {
    $point = New-Object AgtermWin32+Point
    $point.X = $X; $point.Y = $Y
    [AgtermWin32]::ClientToScreen($Window, [ref]$point) | Out-Null
    $point
}

function Get-Hit([IntPtr]$Window, [int]$X, [int]$Y) {
    $screen = Get-ScreenPoint $Window $X $Y
    [int][AgtermWin32]::SendMessageW($Window, 0x0084, [IntPtr]::Zero, [AgtermWin32]::At($screen.X, $screen.Y))
}

# Send-Click is a left click on the client, as the window gets it from the mouse (MK_LBUTTON while it is down).
function Send-Click([IntPtr]$Window, [int]$X, [int]$Y) {
    $at = [AgtermWin32]::At($X, $Y)
    [AgtermWin32]::PostMessageW($Window, 0x0201, [IntPtr]1, $at) | Out-Null
    [AgtermWin32]::PostMessageW($Window, 0x0202, [IntPtr]::Zero, $at) | Out-Null
}

# Send-FrameClick presses and releases a caption button, as Windows reports them with the hit test's code.
function Send-FrameClick([IntPtr]$Window, [int]$Code, [int]$X, [int]$Y) {
    $screen = Get-ScreenPoint $Window $X $Y
    $at = [AgtermWin32]::At($screen.X, $screen.Y)
    [AgtermWin32]::PostMessageW($Window, 0x00A1, [IntPtr]$Code, $at) | Out-Null
    [AgtermWin32]::PostMessageW($Window, 0x00A2, [IntPtr]$Code, $at) | Out-Null
}

function Send-Escape([IntPtr]$Window) {
    [AgtermWin32]::PostMessageW($Window, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero) | Out-Null
}

# Get-Shot draws the window as Save-Snapshot does and keeps where its client starts inside the picture.
function Get-Shot([IntPtr]$Window) {
    $rect = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetWindowRect($Window, [ref]$rect) | Out-Null
    $origin = Get-ScreenPoint $Window 0 0
    $bitmap = New-Object System.Drawing.Bitmap ([Math]::Max(1, $rect.Right - $rect.Left)), ([Math]::Max(1, $rect.Bottom - $rect.Top))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    [AgtermSnapshot]::PrintWindow($Window, $dc, 2) | Out-Null
    $graphics.ReleaseHdc($dc)
    $graphics.Dispose()
    [pscustomobject]@{ Bitmap = $bitmap; X = $origin.X - $rect.Left; Y = $origin.Y - $rect.Top }
}

# Show-Pixels writes a client rectangle into the log as text, one character per 2x2 pixels: '#' bright, '+' mid,
# '.' near the bar's background, for a check whose picture is not at hand.
function Show-Pixels($Shot, [string]$Label, [int]$Left, [int]$Right, [int]$Top, [int]$Bottom) {
    Write-Host "    $Label pixels ($Left..$Right x $Top..$Bottom):"
    for ($y = $Top; $y -lt $Bottom; $y += 2) {
        $line = ""
        for ($x = $Left; $x -lt $Right; $x += 2) {
            $px = $x + $Shot.X; $py = $y + $Shot.Y
            if ($px -lt 0 -or $py -lt 0 -or $px -ge $Shot.Bitmap.Width -or $py -ge $Shot.Bitmap.Height) { $line += " "; continue }
            $c = $Shot.Bitmap.GetPixel($px, $py); $v = ($c.R + $c.G + $c.B) / 3
            $line += if ($v -gt 0x90) { "#" } elseif ($v -gt 0x50) { "+" } elseif ($v -gt 0x30) { "-" } else { "." }
        }
        Write-Host "    |$line|"
    }
}

# Get-InkCount counts the pixels in a client rectangle well off the bar's #252526: a glyph's or the title's.
function Get-InkCount($Shot, [int]$Left, [int]$Right, [int]$Top, [int]$Bottom) {
    $ink = 0
    for ($x = $Left; $x -lt $Right; $x += 1) {
        for ($y = $Top; $y -lt $Bottom; $y += 1) {
            $px = $x + $Shot.X; $py = $y + $Shot.Y
            if ($px -lt 0 -or $py -lt 0 -or $px -ge $Shot.Bitmap.Width -or $py -ge $Shot.Bitmap.Height) { continue }
            $c = $Shot.Bitmap.GetPixel($px, $py)
            if (($c.R + $c.G + $c.B) / 3 -gt 0x50) { $ink++ }
        }
    }
    $ink
}

function Get-SessionNodes([string]$State) {
    @((Invoke-Ctl $State @("tree")).result.tree.workspaces | % { $_.sessions } | ? { $_ })
}

$shellCases["title-bar"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    if ([AgtermWin32]::IsZoomed($window)) { [AgtermWin32]::ShowWindow($window, 9) | Out-Null }
    $failures = @()
    $sidebarPts = (Invoke-Ctl $state @("tree")).result.tree.sidebarWidth
    if (-not $sidebarPts) { $sidebarPts = 220 }
    $bar = Get-Bar $window $sidebarPts

    Note "hit tests"
    $rect = New-Object AgtermWin32+Rect
    [AgtermWin32]::GetWindowRect($window, [ref]$rect) | Out-Null
    $origin = Get-ScreenPoint $window 0 0
    if ($origin.Y -ne $rect.Top) { $failures += "the client starts $($origin.Y - $rect.Top) px below the window's top: Windows' caption is still there" }

    $expected = [ordered]@{ "new session" = $hitClient; quick = $hitClient; split = $hitClient; dashboard = $hitClient
                            find = $hitClient; settings = $hitClient
                            minimize = $hitMinimize; maximize = $hitMaximize; close = $hitClose }
    if ($bar.Spans.file) {
        $expected.file = $hitClient
        if ((Get-Hit $window (Get-Centre $bar "file") $bar.Middle) -ne $hitClient) {
            $failures += "the hit test on the File tab is not client"
        }
    }
    foreach ($part in $expected.Keys) {
        $hit = Get-Hit $window (Get-Centre $bar $part) $bar.Middle
        if ($hit -ne $expected[$part]) { $failures += "the hit test on $part is $hit, not $($expected[$part])" }
    }
    $dragX = [int](($bar.Title[0] + $bar.Title[1]) / 2)
    if (($hit = Get-Hit $window $dragX $bar.Middle) -ne $hitCaption) { $failures += "the hit test on the drag area is $hit, not $hitCaption" }
    if (($hit = Get-Hit $window $dragX 1) -ne $hitTop) { $failures += "the hit test on the top edge is $hit, not $hitTop" }
    if (($hit = Get-Hit $window $dragX ($bar.Height + 20)) -ne $hitClient) { $failures += "the hit test under the bar is $hit, not $hitClient" }

    Note "title follows the session"
    $named = Invoke-Ctl $state @("session", "new", "--name", "title-check", "--command", "powershell.exe -NoLogo -NoProfile")
    if (-not $named.ok) { return $failures + @("session new failed: $($named | ConvertTo-Json -Compress)") }
    if (-not (Wait-Until { [AgtermWin32]::TextOf($window) -eq "title-check" })) {
        $failures += "the window's title is '$([AgtermWin32]::TextOf($window))', not the selected session's 'title-check'"
    }
    Invoke-Ctl $state @("session", "rename", "--target", $named.result.id, "renamed") | Out-Null
    if (-not (Wait-Until { [AgtermWin32]::TextOf($window) -eq "renamed" })) { $failures += "a rename left the title '$([AgtermWin32]::TextOf($window))'" }

    Note "painted bar"
    Start-Sleep -Milliseconds 500
    $shot = Get-Shot $window
    try {
        $c = $shot.Bitmap.GetPixel($dragX + $shot.X, 2 + $shot.Y)
        if ($c.R -gt 0x20 -or $c.G -gt 0x20 -or $c.B -gt 0x20) {
            $failures += "the bar's background is #{0:X2}{1:X2}{2:X2}, expected dark chrome from the terminal theme" -f $c.R, $c.G, $c.B
        }
        foreach ($part in $bar.Spans.Keys) {
            if ($part -match '^(file|view|navigate|help)$') { continue }
            $span = $bar.Spans[$part]
            if ((Get-InkCount $shot $span[0] $span[1] 0 $bar.Height) -lt 4) {
                $failures += "the $part button drew no glyph"
                Show-Pixels $shot $part $span[0] $span[1] 0 $bar.Height
            }
        }
        if ($bar.Spans.file -and (Get-InkCount $shot $bar.Spans.file[0] $bar.Spans.file[1] 0 $bar.Height) -lt 8) {
            $failures += "the File tab drew no label"
        }
        if ((Get-InkCount $shot $bar.Title[0] ([Math]::Min($bar.Title[1], $bar.Title[0] + 200)) 0 $bar.Height) -lt 20) {
            $failures += "the bar drew no title"
        }
    } finally {
        Save-Bitmap $shot.Bitmap (Join-Path $Shell.Dir "title-bar.png")
    }

    Note "+: counting sessions"
    $before = (Get-SessionNodes $state).Count
    Note "+: clicking with $before session(s)"
    Send-Click $window (Get-Centre $bar "new session") $bar.Middle
    $added = Wait-Until { $nodes = Get-SessionNodes $state; if ($nodes.Count -eq $before + 1) { $nodes } }
    if (-not $added) { $failures += "+ left $((Get-SessionNodes $state).Count) session(s), not $($before + 1)" }
    elseif (-not (Wait-Until { $active = Get-SessionNodes $state | ? { $_.active }; $active -and $active.name -eq [AgtermWin32]::TextOf($window) })) {
        $failures += "after + the title is '$([AgtermWin32]::TextOf($window))', not the new session's name"
    }

    Note "find"
    Send-Click $window (Get-Centre $bar "find") $bar.Middle
    if (-not (Wait-Until { [AgtermWin32]::VisibleChildren($window, "Edit").Count -gt 0 } 5)) { $failures += "Find did not show the find bar" }
    Save-Snapshot $Shell "find"

    Note "maximize"
    Send-FrameClick $window $hitMaximize (Get-Centre $bar "maximize") $bar.Middle
    if (-not (Wait-Until { [AgtermWin32]::IsZoomed($window) } 5)) { $failures += "maximize did not maximize" }
    else {
        $monitor = New-Object AgtermWin32+MonitorInfo
        $monitor.Size = [System.Runtime.InteropServices.Marshal]::SizeOf($monitor)
        [AgtermWin32]::GetMonitorInfoW([AgtermWin32]::MonitorFromWindow($window, 2), [ref]$monitor) | Out-Null
        $top = (Get-ScreenPoint $window 0 0).Y
        if ($top -ne $monitor.Work.Top) { $failures += "maximized, the bar starts at $top, not the work area's top $($monitor.Work.Top)" }
        $wide = Get-Bar $window
        if (($hit = Get-Hit $window ([int]($wide.Width / 2)) 1) -ne $hitCaption) { $failures += "maximized, the top edge hit tests $hit, not the drag area" }
        Save-Snapshot $Shell "maximized"
        Send-FrameClick $window $hitMaximize (Get-Centre $wide "maximize") $wide.Middle
        if (-not (Wait-Until { -not [AgtermWin32]::IsZoomed($window) } 5)) { $failures += "restore did not restore" }
    }

    Note "minimize"
    Send-FrameClick $window $hitMinimize (Get-Centre $bar "minimize") $bar.Middle
    if (-not (Wait-Until { [AgtermWin32]::IsIconic($window) } 5)) { $failures += "minimize did not minimize" }
    [AgtermWin32]::ShowWindow($window, 9) | Out-Null
    Wait-Until { -not [AgtermWin32]::IsIconic($window) } 5 | Out-Null

    # sessions still run, so close asks first
    Note "close"
    Send-FrameClick $window $hitClose (Get-Centre $bar "close") $bar.Middle
    if (-not (Wait-Until { [AgtermWin32]::Visible($Shell.Process.Id, "#32770").Count -gt 0 } 5)) {
        $failures += "close with running sessions did not ask before quitting"
    }
    Save-ScreenSnapshot $Shell "quit-question"
    $failures
}

# with no session running, close quits at once
$shellCases["title-bar-close"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $bar = Get-Bar $window
    Send-FrameClick $window $hitClose (Get-Centre $bar "close") $bar.Middle
    if (-not $Shell.Process.WaitForExit(10000)) { @("close did not quit within 10 s") }
}

# Title-bar menu tabs open under the label; a right click on the drag area opens the system menu; on a button, nothing
$shellCases["title-bar-menus"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $processId = $Shell.Process.Id
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $failures = @()
    $sidebarPts = (Invoke-Ctl $Shell.State @("tree")).result.tree.sidebarWidth
    if (-not $sidebarPts) { $sidebarPts = 220 }
    $bar = Get-Bar $window $sidebarPts

    function Test-MenuTab([string]$Label) {
        if (-not $bar.Spans[$Label]) { return @("no $Label tab in the layout") }
        Send-Click $window (Get-Centre $bar $Label) $bar.Middle
        $menu = Wait-Until { [AgtermWin32]::Visible($processId, "#32768") | Select-Object -First 1 } 5
        if (-not $menu) { return @("$Label opened no menu") }
        $ids = [AgtermWin32]::MenuIds($menu)
        $span = $bar.Spans[$Label]
        $under = Get-ScreenPoint $window $span[0] $bar.Height
        $menuRect = New-Object AgtermWin32+Rect
        [AgtermWin32]::GetWindowRect($menu, [ref]$menuRect) | Out-Null
        $out = @()
        if ([Math]::Abs($menuRect.Top - $under.Y) -gt 4 -or [Math]::Abs($menuRect.Left - $under.X) -gt 4) {
            $out += "$Label opened at ($($menuRect.Left), $($menuRect.Top)), not under $($under.X), $($under.Y)"
        }
        Save-ScreenSnapshot $Shell "$Label-menu"
        Send-Escape $menu
        if (-not (Wait-Until { [AgtermWin32]::Visible($processId, "#32768").Count -eq 0 } 5)) { return $out + @("Escape did not close $Label's menu") }
        return ,@($out, $ids)
    }

    Note "Navigate menu"
    $nav = Test-MenuTab "navigate"
    if ($nav[0].Count -gt 0) { $failures += $nav[0] }
    elseif ($nav[1] -notcontains 15) { $failures += "Navigate lacks Find: ids $($nav[1] -join ',')" }

    Note "Help menu"
    $help = Test-MenuTab "help"
    if ($help[0].Count -gt 0) { $failures += $help[0] }
    elseif ($help[1] -notcontains 16) { $failures += "Help lacks Quit: ids $($help[1] -join ',')" }

    Note "system menu"
    $drag = Get-ScreenPoint $window ([int](($bar.Title[0] + $bar.Title[1]) / 2)) $bar.Middle
    [AgtermWin32]::PostMessageW($window, 0x007B, $window, [AgtermWin32]::At($drag.X, $drag.Y)) | Out-Null
    $system = Wait-Until { [AgtermWin32]::Visible($processId, "#32768") | Select-Object -First 1 } 5
    if (-not $system) { $failures += "a right click on the drag area opened no menu" }
    else {
        $ids = [AgtermWin32]::MenuIds($system)
        if (-not ($ids -contains 0xF060)) { $failures += "the drag area's menu is not the system menu: ids $($ids -join ',')" }
        Save-ScreenSnapshot $Shell "system-menu"
        Send-Escape $system
        if (-not (Wait-Until { [AgtermWin32]::Visible($processId, "#32768").Count -eq 0 } 5)) { return $failures + @("Escape did not close the system menu") }
    }

    Note "right click on +"
    $plus = Get-ScreenPoint $window (Get-Centre $bar "new session") $bar.Middle
    [AgtermWin32]::PostMessageW($window, 0x007B, $window, [AgtermWin32]::At($plus.X, $plus.Y)) | Out-Null
    Start-Sleep -Milliseconds 1500
    if ([AgtermWin32]::Visible($processId, "#32768").Count -gt 0) { $failures += "a right click on + opened a menu" }
    $failures
}
