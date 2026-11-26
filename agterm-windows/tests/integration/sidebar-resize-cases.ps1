# Real pointer input must reach the divider through Windows hit testing (#62).
# Posting button messages directly to the shell would bypass the child windows that swallow the drag.
$shellCases["sidebar-resize"] = {
    param($Shell)
    $state = $Shell.State
    $window = Get-ShellWindow $Shell
    if (-not $window) { return @("no visible agterm-shell window") }
    $oldDpi = [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4))
    $failures = @()
    try {
        $id = New-PowerShellSession $state
        if (-not $id -or -not (Wait-Prompt $state $id)) { return @("the local shell never reached its prompt") }
        Invoke-Ctl $state @("sidebar", "width", "260") | Out-Null
        $bar = Get-Bar $window 260
        $caption = Get-ScreenPoint $window ([int](($bar.Title[0] + $bar.Title[1]) / 2)) $bar.Middle
        if (-not [AgtermInput]::Front($window, $caption.X, $caption.Y)) { return @("could not bring the test window to the foreground for real mouse input") }
        $scale = [AgtermWin32]::GetDpiForWindow($window) / 96.0
        $y = $bar.ContentTop + [int](80 * $scale)
        $tree = [AgtermWin32]::VisibleChildren($window, "SysTreeView32") | Select-Object -First 1
        $terminal = Get-Panes $window | Select-Object -First 1
        if (-not $tree -or -not $terminal) { return @("the sidebar or local terminal is not visible") }
        Save-Snapshot $Shell "sidebar-before-drag"

        # Grab from both sides of the boundary, resize both ways, and hit the minimum clamp.
        foreach ($step in @(@{ offset = -2; target = 340; expected = 340 },
                            @{ offset = 2; target = 220; expected = 220 },
                            @{ offset = -2; target = 120; expected = 160 },
                            @{ offset = 2; target = 300; expected = 300 })) {
            $before = [double]((Invoke-Ctl $state @("tree")).result.tree.sidebarWidth)
            $beforeRect = Get-Rect $tree
            $beforeTerminal = Get-Rect $terminal
            $from = Get-ScreenPoint $window ([int][Math]::Round(($before + $step.offset) * $scale)) $y
            $to = Get-ScreenPoint $window ([int][Math]::Round($step.target * $scale)) $y
            Note "drag sidebar from $before pt to $($step.target) pt (grab offset $($step.offset) pt)"
            [AgtermInput]::Drag($from.X, $from.Y, $to.X, $to.Y)
            $updated = Wait-Until {
                $value = [double]((Invoke-Ctl $state @("tree")).result.tree.sidebarWidth)
                if ([Math]::Abs($value - $step.expected) -le 2) { $true }
            } 5
            Save-Snapshot $Shell ("sidebar-drag-to-" + $step.target)
            if (-not $updated) {
                $actual = (Invoke-Ctl $state @("tree")).result.tree.sidebarWidth
                return @("real drag from $before pt to $($step.target) pt left sidebar width $actual pt; expected $($step.expected) pt")
            }
            $delta = ($step.expected - $before) * $scale
            $afterRect = Get-Rect $tree
            $afterTerminal = Get-Rect $terminal
            if ([Math]::Abs(($afterRect.Right - $beforeRect.Right) - $delta) -gt 3) { $failures += "the sidebar window did not follow the resized width" }
            if ([Math]::Abs(($afterTerminal.Left - $beforeTerminal.Left) - $delta) -gt 3) { $failures += "the terminal did not move with the sidebar boundary" }
            if (-not (Wait-Until { [Math]::Abs([double]((Get-Saved $state).sidebarWidthPoints) - $step.expected) -le 2 } 5)) {
                $failures += "releasing the divider did not save width $($step.expected) pt"
            }
        }

        Note "restore the dragged width after restarting the app"
        Stop-Shell $Shell
        $again = Start-Shell (Split-Path $Shell.Dir -Leaf) $null @{ CaseWaits = $true }
        $watchdog = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @("-NoProfile", "-Command",
            "Start-Sleep -Seconds 60; Stop-Process -Id $($again.Process.Id) -Force -ErrorAction SilentlyContinue")
        try {
            if (-not (Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30)) { return $failures + @("the restarted app did not answer") }
            $restored = (Invoke-Ctl $state @("tree")).result.tree.sidebarWidth
            if ([Math]::Abs([double]$restored - 300) -gt 2) { $failures += "restart restored width $restored pt instead of the dragged 300 pt" }
            Save-Snapshot $again "sidebar-after-restart"
        } finally {
            Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue
            Stop-Shell $again
        }
    } finally {
        if ($oldDpi -ne [IntPtr]::Zero) { [AgtermWin32]::SetThreadDpiAwarenessContext($oldDpi) | Out-Null }
    }
    $failures
}
