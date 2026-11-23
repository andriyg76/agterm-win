# The palettes' cases: Ctrl+P and Ctrl+Shift+P go in as real keystrokes, a query is the field's text, Enter, Esc and
# the arrows are posted to the field, and a click away is a real click. Rows are read back from the list, the outcome
# through agtermctl. Dot-sourced by shell-cases.ps1 after title-bar-cases.ps1, whose AgtermWin32 helpers it uses.

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AgtermInput {
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, string text);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, StringBuilder text);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    // Chord presses `key` with Ctrl, and Shift when asked, as the keyboard does.
    public static void Chord(byte key, bool shift) {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        if (shift) keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
        if (shift) keybd_event(0x10, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }

    // Front brings a window forward; an Alt tap first lets a background process do it.
    public static bool Front(IntPtr window) {
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(window);
        return GetForegroundWindow() == window;
    }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x02, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x04, 0, 0, 0, UIntPtr.Zero);
    }

    public static void SetText(IntPtr edit, string text) { SendMessageW(edit, 0x000C, IntPtr.Zero, text); }

    public static string[] Rows(IntPtr list) {
        int count = (int)SendMessageW(list, 0x018B, IntPtr.Zero, IntPtr.Zero);
        var rows = new string[Math.Max(count, 0)];
        for (int i = 0; i < rows.Length; i++) {
            int length = (int)SendMessageW(list, 0x018A, (IntPtr)i, IntPtr.Zero);
            var text = new StringBuilder(Math.Max(length, 0) + 1);
            SendMessageW(list, 0x0189, (IntPtr)i, text);
            rows[i] = text.ToString();
        }
        return rows;
    }

    public static int Highlight(IntPtr list) { return (int)SendMessageW(list, 0x0188, IntPtr.Zero, IntPtr.Zero); }
}
'@

function Get-Palette([IntPtr]$Window) {
    $panel = [AgtermWin32]::VisibleChildren($Window, "agterm-palette") | Select-Object -First 1
    if (-not $panel) { return $null }
    [pscustomobject]@{
        Panel = $panel
        Edit = [AgtermWin32]::VisibleChildren($panel, "Edit") | Select-Object -First 1
        List = [AgtermWin32]::VisibleChildren($panel, "ListBox") | Select-Object -First 1
    }
}

function Get-Rows($Palette) { if ($Palette.List) { @([AgtermInput]::Rows($Palette.List)) } else { @() } }

# Open-Palette presses the chord and waits for the panel; nothing comes back when the window is not in front.
function Open-Palette([IntPtr]$Window, [bool]$Shift) {
    if (-not [AgtermInput]::Front($Window)) { return $null }
    [AgtermInput]::Chord(0x50, $Shift)
    Wait-Until { Get-Palette $Window } 5
}

function Send-Key([IntPtr]$Edit, [int]$Key) {
    [AgtermWin32]::PostMessageW($Edit, 0x0100, [IntPtr]$Key, [IntPtr]::Zero) | Out-Null
}

function Get-Active([string]$State) { Get-SessionNodes $State | ? { $_.active } | Select-Object -First 1 }

$shellCases["palettes"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $failures = @()
    foreach ($name in @("gamma-db", "alpha-api", "beta-web")) {
        $reply = Invoke-Ctl $state @("session", "new", "--name", $name, "--command", "cmd.exe /d /k")
        if (-not $reply.ok) { return @("session new $name failed: $($reply | ConvertTo-Json -Compress)") }
    }
    if (-not [AgtermInput]::Front($window)) { return @("the window could not be brought to the front, so no key reaches it") }

    Note "Ctrl+P"
    $palette = Open-Palette $window $false
    if (-not $palette) { return @("Ctrl+P opened no palette") }
    $rows = Get-Rows $palette
    if (($rows -join "|") -ne "alpha-api|beta-web|gamma-db") { $failures += "Ctrl+P lists '$($rows -join "|")', not the sessions A to Z" }
    if ([AgtermInput]::Highlight($palette.List) -ne 0) { $failures += "Ctrl+P opened without the first row highlighted" }
    Save-Snapshot $Shell "session-palette"
    [AgtermInput]::SetText($palette.Edit, "gam")
    if (-not (Wait-Until { ((Get-Rows $palette) -join "|") -eq "gamma-db" } 5)) { $failures += "'gam' leaves '$((Get-Rows $palette) -join "|")'" }
    Send-Key $palette.Edit 0x0D
    if (-not (Wait-Until { -not (Get-Palette $window) } 5)) { $failures += "Enter left the session palette open" }
    if (-not (Wait-Until { (Get-Active $state).name -eq "gamma-db" } 5)) { $failures += "Enter selected '$((Get-Active $state).name)', not gamma-db" }

    $palette = Open-Palette $window $false
    Note "arrows and Ctrl+J/K"
    if (-not $palette) { return $failures + @("Ctrl+P did not open the palette again") }
    Send-Key $palette.Edit 0x28
    if (-not (Wait-Until { [AgtermInput]::Highlight($palette.List) -eq 1 } 2)) { $failures += "Down left the highlight on $([AgtermInput]::Highlight($palette.List))" }
    [AgtermInput]::Chord(0x4A, $false)
    if (-not (Wait-Until { [AgtermInput]::Highlight($palette.List) -eq 2 } 2)) { $failures += "Ctrl+J left the highlight on $([AgtermInput]::Highlight($palette.List))" }
    [AgtermInput]::Chord(0x4B, $false)
    if (-not (Wait-Until { [AgtermInput]::Highlight($palette.List) -eq 1 } 2)) { $failures += "Ctrl+K left the highlight on $([AgtermInput]::Highlight($palette.List))" }
    if ([AgtermWin32]::TextOf($palette.Edit) -ne "") { $failures += "Ctrl+J/K typed '$([AgtermWin32]::TextOf($palette.Edit))' into the field" }
    Send-Key $palette.Edit 0x0D
    if (-not (Wait-Until { (Get-Active $state).name -eq "beta-web" } 5)) { $failures += "the arrows then Enter selected '$((Get-Active $state).name)', not beta-web" }

    $palette = Open-Palette $window $false
    if ($palette) {
        Send-Key $palette.Edit 0x1B
        if (-not (Wait-Until { -not (Get-Palette $window) } 5)) { $failures += "Esc left the palette open" }
        if ((Get-Active $state).name -ne "beta-web") { $failures += "Esc changed the session to '$((Get-Active $state).name)'" }
    } else { $failures += "Ctrl+P did not open the palette for Esc" }

    $palette = Open-Palette $window $false
    if ($palette) {
        $bar = Get-Bar $window
        $terminal = Get-ScreenPoint $window ([int]($bar.Width - 60)) ([int]($bar.Height + 200))
        [AgtermInput]::Click($terminal.X, $terminal.Y)
        if (-not (Wait-Until { -not (Get-Palette $window) } 5)) { $failures += "a click on the terminal left the palette open" }
    } else { $failures += "Ctrl+P did not open the palette for the click away" }

    Note "Ctrl+Shift+P"
    $palette = Open-Palette $window $true
    if (-not $palette) { return $failures + @("Ctrl+Shift+P opened no palette") }
    $rows = Get-Rows $palette
    foreach ($title in @("Find…", "Quit", "Go to Session…", "New Session › Windows PowerShell")) {
        if ($rows -notcontains $title) { $failures += "Ctrl+Shift+P lacks '$title'" }
    }
    if ($rows -contains "Command Palette…") { $failures += "Ctrl+Shift+P lists itself" }
    Save-Snapshot $Shell "command-palette"

    # no session has exited, so Restart Session is listed but does nothing
    [AgtermInput]::SetText($palette.Edit, "restart session")
    if (-not (Wait-Until { (Get-Rows $palette)[0] -eq "Restart Session" } 5)) { $failures += "'restart session' leads with '$((Get-Rows $palette)[0])'" }
    Send-Key $palette.Edit 0x0D
    Start-Sleep -Milliseconds 800
    if (-not (Get-Palette $window)) { $failures += "Enter on the disabled Restart Session closed the palette" }

    $before = (Get-SessionNodes $state).Count
    [AgtermInput]::SetText($palette.Edit, "new session windows")
    if (-not (Wait-Until { (Get-Rows $palette)[0] -eq "New Session › Windows PowerShell" } 5)) {
        $failures += "'new session windows' leads with '$((Get-Rows $palette)[0])'"
    }
    Send-Key $palette.Edit 0x0D
    if (-not (Wait-Until { (Get-SessionNodes $state).Count -eq $before + 1 } 10)) { $failures += "New Session from the palette left $((Get-SessionNodes $state).Count) session(s)" }

    # a palette row that opens the other palette leaves it open
    $palette = Open-Palette $window $true
    if ($palette) {
        [AgtermInput]::SetText($palette.Edit, "go to session")
        Wait-Until { (Get-Rows $palette)[0] -eq "Go to Session…" } 5 | Out-Null
        Send-Key $palette.Edit 0x0D
        $sessions = Wait-Until { $p = Get-Palette $window; if ($p -and (Get-Rows $p) -contains "alpha-api") { $p } } 5
        Start-Sleep -Milliseconds 800
        if (-not $sessions -or -not (Get-Palette $window)) { $failures += "Go to Session… from the command palette did not leave the session palette open" }
    } else { $failures += "Ctrl+Shift+P did not open the palette again" }
    $failures
}
