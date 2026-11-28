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
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint to, bool on);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr window);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo {
        public int Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string className, string title);

    // Child finds a child by class whether it is shown or not: the list shows only once its rows arrive.
    public static IntPtr Child(IntPtr parent, string className) { return FindWindowExW(parent, IntPtr.Zero, className, null); }

    // FocusOf is the window with keyboard focus on `window`'s thread.
    public static IntPtr FocusOf(IntPtr window) {
        var info = new GuiThreadInfo();
        info.Size = Marshal.SizeOf(info);
        GetGUIThreadInfo(GetWindowThreadProcessId(window, IntPtr.Zero), ref info);
        return info.Focus;
    }

    // SendChord is Chord for a window Windows will not put in front: attached to its thread, the case holds Ctrl (and
    // Shift) in their shared key state and sends the key to the window with focus, whose own GetKeyState then reads
    // the chord, so the keymap is what turns it into a command.
    public static void SendChord(IntPtr window, byte key, bool shift) { SendChord(window, key, shift, false); }
    public static void SendChord(IntPtr window, byte key, bool shift, bool alt) {
        uint mine = GetCurrentThreadId(), theirs = GetWindowThreadProcessId(window, IntPtr.Zero);
        bool attached = AttachThreadInput(mine, theirs, true);
        try {
            var state = new byte[256];
            GetKeyboardState(state);
            state[0x11] = state[0xA2] = 0x80;
            if (shift) state[0x10] = state[0xA0] = 0x80;
            if (alt) state[0x12] = state[0xA4] = 0x80;
            SetKeyboardState(state);
            var info = new GuiThreadInfo();
            info.Size = Marshal.SizeOf(info);
            GetGUIThreadInfo(theirs, ref info);
            IntPtr target = info.Focus != IntPtr.Zero ? info.Focus : window;
            SendMessageW(target, 0x0100, (IntPtr)key, (IntPtr)1);
            SendMessageW(target, 0x0101, (IntPtr)key, (IntPtr)unchecked((int)0xC0000001));
            state[0x11] = state[0xA2] = state[0x10] = state[0xA0] = 0;
            if (alt) state[0x12] = state[0xA4] = 0;
            SetKeyboardState(state);
        } finally {
            if (attached) AttachThreadInput(mine, theirs, false);
        }
    }

    // FocusOn moves the keyboard focus to `window` through its thread, as a click on it would.
    public static void FocusOn(IntPtr window) {
        uint mine = GetCurrentThreadId(), theirs = GetWindowThreadProcessId(window, IntPtr.Zero);
        bool attached = AttachThreadInput(mine, theirs, true);
        SetFocus(window);
        if (attached) AttachThreadInput(mine, theirs, false);
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, string text);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, StringBuilder text);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    // Chord presses `key` with Ctrl, and Shift when asked, as the keyboard does.
    public static void Chord(byte key, bool shift, bool alt) {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        if (shift) keybd_event(0x10, 0, 0, UIntPtr.Zero);
        if (alt) keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
        if (alt) keybd_event(0x12, 0, 2, UIntPtr.Zero);
        if (shift) keybd_event(0x10, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }

    // Front brings a window forward: an Alt tap lets a background process ask, and where Windows still refuses, a
    // click at (x, y), the window's drag area, activates it as a user would.
    public static bool Front(IntPtr window, int x, int y) {
        if (GetForegroundWindow() == window) return true;
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(window);
        for (int i = 0; i < 20 && GetForegroundWindow() != window; i++) {
            if (i == 2) Click(x, y);
            if (i == 5) Take(window);
            System.Threading.Thread.Sleep(100);
        }
        return GetForegroundWindow() == window;
    }

    // Take borrows the foreground window's input queue for the request, which Windows then grants: keystrokes
    // reach the window in front even while a flyout still covers it.
    static void Take(IntPtr window) {
        uint mine = GetCurrentThreadId(), theirs = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        bool attached = theirs != 0 && theirs != mine && AttachThreadInput(mine, theirs, true);
        BringWindowToTop(window);
        SetForegroundWindow(window);
        if (attached) AttachThreadInput(mine, theirs, false);
    }

    public static void Press(byte key) {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }

    // Real mouse input lets Windows select the child window under the pointer, unlike SendMessage to a parent.
    public static void Drag(int fromX, int fromY, int toX, int toY) {
        SetCursorPos(fromX, fromY);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x02, 0, 0, 0, UIntPtr.Zero);
        try {
            for (int step = 1; step <= 16; step++) {
                SetCursorPos(fromX + (toX - fromX) * step / 16, fromY + (toY - fromY) * step / 16);
                System.Threading.Thread.Sleep(20);
            }
            // a hand holds still before letting go; without the pause the release can outrun the last move's handling
            System.Threading.Thread.Sleep(150);
        } finally {
            mouse_event(0x04, 0, 0, 0, UIntPtr.Zero);
        }
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
        Edit = [AgtermInput]::Child($panel, "Edit")
        List = [AgtermInput]::Child($panel, "ListBox")
    }
}

function Get-Rows($Palette) { if ($Palette.List) { @([AgtermInput]::Rows($Palette.List)) } else { @() } }

# Bring-Front brings the window forward: asked, then by a click on the middle of its drag area, then by borrowing the
# foreground's input queue, which a Windows flyout in front (the arm64 runner's "Microsoft account" prompt) needs.
function Bring-Front([IntPtr]$Window) {
    $bar = Get-Bar $Window
    $drag = Get-ScreenPoint $Window ([int](($bar.Title[0] + $bar.Title[1]) / 2)) $bar.Middle
    [AgtermInput]::Front($Window, $drag.X, $drag.Y)
}

# $InFront says whether the window could be brought forward, so keys and clicks go in as real input, or only through
# its thread (SendChord, FocusOn) while a Windows flyout keeps the foreground.
$script:InFront = $true

function Send-Chord([IntPtr]$Window, [byte]$Key, [bool]$Shift, [bool]$Alt = $false) {
    if ($script:InFront) { [AgtermInput]::Chord($Key, $Shift, $Alt) } else { [AgtermInput]::SendChord($Window, $Key, $Shift, $Alt) }
}

# Open-Palette presses the chord and waits for the panel.
function Open-Palette([IntPtr]$Window, [bool]$Shift) {
    if ($script:InFront -and -not (Bring-Front $Window)) { return $null }
    Send-Chord $Window ([byte]0x50) $Shift
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
    $script:InFront = Bring-Front $window
    if (-not $script:InFront) {
        $front = [AgtermInput]::GetForegroundWindow()
        Note "Windows keeps '$([AgtermWin32]::ClassOf($front))' '$([AgtermWin32]::TextOf($front))' in front: keys go in through the window's thread"
        # a window out of the foreground may have no focused child, and the main window reads no keys itself
        [AgtermInput]::FocusOn(([AgtermWin32]::VisibleChildren($window, "agterm-native") | Select-Object -First 1))
    }

    Note "Ctrl+P"
    $palette = Open-Palette $window $false
    if (-not $palette) { return @("Ctrl+P opened no palette") }
    Wait-Until { @(Get-Rows $palette).Count -ge 3 } 5 | Out-Null
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
    Send-Chord $window ([byte]0x4A) $false
    if (-not (Wait-Until { [AgtermInput]::Highlight($palette.List) -eq 2 } 2)) { $failures += "Ctrl+J left the highlight on $([AgtermInput]::Highlight($palette.List))" }
    Send-Chord $window ([byte]0x4B) $false
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
        if ($script:InFront) { [AgtermInput]::Click($terminal.X, $terminal.Y) }
        else { [AgtermInput]::FocusOn(([AgtermWin32]::VisibleChildren($window, "agterm-native") | Select-Object -First 1)) }
        if (-not (Wait-Until { -not (Get-Palette $window) } 5)) { $failures += "a click on the terminal left the palette open" }
    } else { $failures += "Ctrl+P did not open the palette for the click away" }

    Note "Ctrl+Shift+P"
    $palette = Open-Palette $window $true
    if (-not $palette) { return $failures + @("Ctrl+Shift+P opened no palette") }
    Wait-Until { @(Get-Rows $palette).Count -gt 5 } 5 | Out-Null
    $rows = Get-Rows $palette
    foreach ($title in @("View › Find…", "Quit", "Go to Session…", "New Session › Windows PowerShell")) {
        if ($rows -notcontains $title) { $failures += "Ctrl+Shift+P lacks '$title'" }
    }
    if ($rows -contains "Command Palette…") { $failures += "Ctrl+Shift+P lists itself" }
    Save-Snapshot $Shell "command-palette"

    # no session has exited, so Restart Session is listed but does nothing
    [AgtermInput]::SetText($palette.Edit, "restart session")
    if (-not (Wait-Until { @(Get-Rows $palette)[0] -eq "Restart Session" } 5)) { $failures += "'restart session' leads with '$(@(Get-Rows $palette)[0])'" }
    Send-Key $palette.Edit 0x0D
    Start-Sleep -Milliseconds 800
    if (-not (Get-Palette $window)) { $failures += "Enter on the disabled Restart Session closed the palette" }

    $before = @(Get-SessionNodes $state).Count
    [AgtermInput]::SetText($palette.Edit, "new session windows")
    if (-not (Wait-Until { @(Get-Rows $palette)[0] -eq "New Session › Windows PowerShell" } 5)) {
        $failures += "'new session windows' leads with '$(@(Get-Rows $palette)[0])'"
    }
    Send-Key $palette.Edit 0x0D
    if (-not (Wait-Until { @(Get-SessionNodes $state).Count -eq $before + 1 } 10)) { $failures += "New Session from the palette left $(@(Get-SessionNodes $state).Count) session(s)" }

    # a palette row that opens the other palette leaves it open
    $palette = Open-Palette $window $true
    if ($palette) {
        [AgtermInput]::SetText($palette.Edit, "go to session")
        Wait-Until { @(Get-Rows $palette)[0] -eq "Go to Session…" } 5 | Out-Null
        Send-Key $palette.Edit 0x0D
        $sessions = Wait-Until { $p = Get-Palette $window; if ($p -and (Get-Rows $p) -contains "alpha-api") { $p } } 5
        Start-Sleep -Milliseconds 800
        if (-not $sessions -or -not (Get-Palette $window)) { $failures += "Go to Session… from the command palette did not leave the session palette open" }
    } else { $failures += "Ctrl+Shift+P did not open the palette again" }
    $failures
}

$shellCases["attention-close-shortcuts"] = {
    param($Shell)
    [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $state = $Shell.State
    $blocked = Invoke-Ctl $state @("session", "new", "--name", "waiting", "--command", "cmd.exe /d /k")
    $idle = Invoke-Ctl $state @("session", "new", "--name", "idle", "--command", "cmd.exe /d /k")
    if (-not $blocked.ok -or -not $idle.ok) { return @("could not create test sessions") }
    $status = Invoke-Ctl $state @("session", "status", "blocked", "--target", $blocked.result.id)
    if (-not $status.ok) { return @("could not set the waiting session's status") }
    $script:InFront = Bring-Front $window
    $terminal = [AgtermWin32]::VisibleChildren($window, "agterm-native") | Select-Object -First 1
    if (-not $terminal) { return @("no visible terminal") }
    [AgtermInput]::FocusOn($terminal)
    Send-Chord $window 0x49 $false $true
    $palette = Wait-Until { Get-Palette $window } 5
    if (-not $palette) { return @("Ctrl+Alt+I opened no Attention palette") }
    if (-not (Wait-Until { ((Get-Rows $palette) -join "|") -eq "waiting" } 5)) { return @("Attention did not list only the blocked session") }
    Send-Key $palette.Edit 0x0D
    if (-not (Wait-Until { (Get-Active $state).id -eq $blocked.result.id } 5)) { return @("Attention did not select the waiting session") }

    # Exercise the real message loop with the tree focused when the desktop grants foreground access.
    if ($script:InFront) {
        $tree = [AgtermWin32]::VisibleChildren($window, "SysTreeView32") | Select-Object -First 1
        if (-not $tree) { return @("no sidebar tree") }
        [AgtermInput]::FocusOn($tree)
        Send-Chord $window 0x49 $false $true
        $palette = Wait-Until { Get-Palette $window } 5
        if (-not $palette) { return @("Ctrl+Alt+I from the sidebar opened no Attention palette") }
        Send-Key $palette.Edit 0x1B
        if (-not (Wait-Until { -not (Get-Palette $window) } 5)) { return @("Escape did not close Attention") }
        [AgtermInput]::FocusOn($tree)
    }
    Send-Chord $window 0x73 $false
    if (-not (Wait-Until { $null -eq (Get-SessionNodes $state | Where-Object { $_.id -eq $blocked.result.id }) } 5)) {
        return @("Ctrl+F4 did not close the selected session")
    }
    if (-not (Get-SessionNodes $state | Where-Object { $_.id -eq $idle.result.id })) { return @("Ctrl+F4 also closed the other session") }
    @()
}
