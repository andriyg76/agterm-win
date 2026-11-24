# Optional integration gate for a real WSL distribution with agterm-server. CI does not run this; it uses the
# agterm-test-absent cases in wsl-cases.ps1 instead.
param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Results,
    [string]$Distribution = "Ubuntu",
    [ValidateRange(30, 600)][int]$CaseTimeoutSeconds = 180
)
$ErrorActionPreference = "Stop"
$exe = Join-Path (Resolve-Path $App) "agterm-win.exe"
if (-not (Test-Path $exe)) { throw "no agterm-win.exe in $App" }
$list = & wsl.exe -l -q 2>&1 | Out-String
if ($list -notmatch [regex]::Escape($Distribution)) { throw "WSL distribution '$Distribution' is not installed" }
$active = (& wsl.exe -d $Distribution -e bash -lc "systemctl --user is-active agterm-server 2>/dev/null").Trim()
if ($active -ne "active") { throw "agterm-server is not active in $Distribution (got '$active'); install it first" }

New-Item -ItemType Directory -Force $Results | Out-Null
$Results = (Resolve-Path $Results).Path
. (Join-Path $PSScriptRoot "shell-cases.ps1")

$shellPreparations["wsl-ensure-live"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$Distribution`": `"atLaunch`"}}"
}
$shellCases["wsl-ensure-live"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $null = Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30
    $server = Wait-Until {
        $s = (Invoke-Ctl $state @("wsl", "list")).result.wsl | ? { $_.distribution -eq $Distribution } | Select-Object -First 1
        if ($s.started -and $s.connected) { $s }
    } 60
    if (-not $server) {
        return @("$Distribution did not connect; check agterm-win.log and the sidebar notice")
    }
    $log = Get-AgtermWinLog $state
    if (-not $log.Contains("wsl inspect $Distribution")) { $failures += "log lacks wsl inspect" }
    if ($log.Contains("downloading https://github.com/umputun/agterm/releases") -and $log -notmatch "needs ") {
        # a matching install is fine after a version bump; a probe-only launch should not download needlessly
    }
    $workspaces = (Invoke-Ctl $state @("tree")).result.tree.wslServers | ? { $_.label -match $Distribution }
    if (-not $workspaces) { $failures += "tree shows no catalog for $Distribution" }
    Save-Snapshot $Shell "live-connected"
    $failures
}

$failures = Invoke-ShellCase "wsl-ensure-live"
if ($failures) {
    Write-Host "FAIL wsl-server-gate: $($failures -join '; ')"
    exit 1
}
Write-Host "PASS wsl-server-gate ($Distribution connected)"
exit 0