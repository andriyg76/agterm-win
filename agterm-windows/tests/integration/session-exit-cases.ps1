# Needs a staged client and server with the exit-retention change, and AGTERM_WIN_GATE_WSL.
$shellPreparations["remote-exit-buffer"] = {
    param($state)
    $dist = $env:AGTERM_WIN_GATE_WSL
    Set-RemoteProperties $state @($dist) @{ $dist = "atLaunch" }
}
$shellCases["remote-exit-buffer"] = {
    param($Shell)
    $state = $Shell.State
    $dist = $env:AGTERM_WIN_GATE_WSL
    if (-not (Wait-Until { (Get-WSLServer $state $dist).connected } 120)) { return @("$dist never connected") }
    $created = Invoke-Ctl $state @("session", "new", "--remote", $dist, "--name", "remote-buffer-gate")
    if (-not $created.ok) { return @("remote session creation failed: $($created.error)") }
    $id = $created.result.id
    $other = $null
    $failures = @()
    try {
        if (-not (Wait-Until { Get-Node $state $id } 15)) { return @("the new remote session never appeared") }
        Invoke-Ctl $state @("session", "select", "--target", $id) | Out-Null
        if (-not (Wait-Prompt $state $id)) { return @("the remote shell never reached its prompt") }
        $name = "remote-buffer-gate"
        Invoke-Ctl $state @("session", "rename", $name, "--target", $id) | Out-Null
        $window = Get-ShellWindow $Shell
        $terminal = Get-Panes $window | Select-Object -First 1
        Invoke-Ctl $state @("session", "type", "printf '\nremote-buffer-output\n'; exit 7`r", "--target", $id) | Out-Null
        if (-not (Wait-Until { (Get-Node $state $id).ended } 15)) { return @("the exited remote session was removed instead of retained as ended") }
        if (-not (Wait-Until { (Invoke-Ctl $state @("session", "text", "--all", "--target", $id)).result.text -match "\[process exited with code" } 15)) {
            return @("the remote attach never drained its final output")
        }
        $before = (Invoke-Ctl $state @("session", "text", "--all", "--target", $id)).result.text
        if ($before -notmatch "remote-buffer-output") { $failures += "the ended session lost its output" }

        $other = New-PowerShellSession $state
        if (-not $other -or -not (Wait-Prompt $state $other)) { return $failures + @("could not switch to a local session") }
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        [AgtermWin32]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
        $tree = [AgtermWin32]::VisibleChildren($window, "SysTreeView32") | Select-Object -First 1
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($tree)
        $rows = $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        $row = $rows | Where-Object { $_.Current.Name -like "*$name*" } | Select-Object -First 1
        if (-not $row) { return $failures + @("the ended session has no selectable sidebar row") }
        $bounds = $row.Current.BoundingRectangle
        $rect = Get-Rect $tree
        Send-Click $tree ([int]($bounds.Left + $bounds.Width / 2 - $rect.Left)) ([int]($bounds.Top + $bounds.Height / 2 - $rect.Top))
        if (-not (Wait-Until { (Get-Panes $window) -contains $terminal } 5)) { $failures += "clicking the ended row did not show its retained terminal" }
        $after = (Invoke-Ctl $state @("session", "text", "--all", "--target", $id)).result.text
        if ($after -ne $before) { $failures += "selecting the ended row replaced its buffer" }
        Save-Snapshot $Shell "remote-ended-buffer"

        $closed = Invoke-Ctl $state @("session", "close", "--target", $id)
        if (-not $closed.ok -or -not (Wait-Until { -not (Get-Node $state $id) } 10)) { $failures += "explicit close left the session in the catalog" }
        if (-not (Wait-Until { -not [AgtermWin32]::IsWindow($terminal) } 5)) { $failures += "explicit close did not destroy the retained terminal" }
    } finally {
        if ($id) { Invoke-Ctl $state @("session", "close", "--target", $id) | Out-Null }
        if ($other) { Invoke-Ctl $state @("session", "close", "--target", $other) | Out-Null }
    }
    $failures
}
