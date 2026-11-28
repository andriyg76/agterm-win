# Optional integration gate for a real WSL distribution with agterm-server. GitHub-hosted CI does not run this; it uses the
# agterm-test-absent cases in wsl-cases.ps1 instead; windows-gate.yml runs it on a self-hosted box.
param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Results,
    [Parameter(Mandatory)][string]$Distribution,
    [ValidateRange(30, 600)][int]$CaseTimeoutSeconds = 180
)
$ErrorActionPreference = "Stop"
$exe = Join-Path (Resolve-Path $App) "agterm-win.exe"
if (-not (Test-Path $exe)) { throw "no agterm-win.exe in $App" }
# wsl.exe lists in UTF-16, which PowerShell 5.1 reads with a NUL after every character
$list = (& wsl.exe -l -q 2>&1 | Out-String) -replace "`0", ""
if ($list -notmatch [regex]::Escape($Distribution)) { throw "WSL distribution '$Distribution' is not installed" }
# the server's own reply, as the app's probe reads it: systemctl can lose the user bus under WSL; a distribution WSL
# had stopped boots on this call and its user manager starts the server a few seconds later
$ErrorActionPreference = "Continue"
for ($try = 0; $try -lt 20; $try++) {
    $version = (& wsl.exe -d $Distribution -e /bin/sh -c '"$HOME/.local/bin/agtermctl" version --json' 2>&1 | Out-String)
    if ($version -match '"server"') { break }
    Start-Sleep -Seconds 1
}
$ErrorActionPreference = "Stop"
if ($version -notmatch '"server"') { throw "agterm-server does not answer in $Distribution ($($version.Trim())); install it first" }

New-Item -ItemType Directory -Force $Results | Out-Null
$Results = (Resolve-Path $Results).Path
. (Join-Path $PSScriptRoot "shell-cases.ps1")

# no remote.properties: the first launch writes it from wsl -l -q before the start at launch resolves the name
$shellPreparations["wsl-ensure-live"] = {
    param($state) Set-Content (Join-Path $state "native.json") "{`"serverLaunch`": {`"$Distribution`": `"atLaunch`"}}"
}
$shellCases["wsl-ensure-live"] = {
    param($Shell)
    $state = $Shell.State
    $failures = @()
    $null = Wait-Until { (Invoke-Ctl $state @("tree")).ok } 30
    $server = Wait-Until { $s = Get-WSLServer $state $Distribution; if ($s.started -and $s.connected) { $s } } 60
    if (-not $server) {
        return @("$Distribution did not connect; check agterm-win.log and the sidebar notice")
    }
    $log = Get-AgtermWinLog $state
    if (-not $log.Contains("remote inspect $Distribution")) { $failures += "log lacks remote inspect" }
    if ($log.Contains("not defined in remote.properties")) { $failures += "the start found $Distribution undefined" }
    $notice = (Get-WSLBootstrapNotices $Shell) -join "`n"
    if ($notice -match "not reachable|failed") { $failures += "the notice bar shows '$notice'" }
    if ($log.Contains("downloading https://github.com/umputun/agterm/releases") -and $log -notmatch "needs ") {
        # a matching install is fine after a version bump; a probe-only launch should not download needlessly
    }
    $created = Invoke-Ctl $state @("session", "new", "--remote", $Distribution, "--workspace-name", "gate")
    if (-not $created.ok) { return $failures + @("session new --remote replied $($created | ConvertTo-Json -Compress)") }
    $node = Wait-Until { Get-Node $state $created.result.id } 30
    if ($node.remoteHost -ne $Distribution) { $failures += "the new session reads remoteHost '$($node.remoteHost)'" }
    $id = $created.result.id
    Invoke-Ctl $state @("session", "select", "--target", $id) | Out-Null
    # the shell's own arithmetic into a file read back through wsl.exe: a window started minimized has a 1x1 grid
    $marker = "/tmp/agterm-gate-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Invoke-Ctl $state @("session", "type", "--target", $id, "echo `$((6*7)) > $marker`r") | Out-Null
    $ran = Wait-Until { (& wsl.exe -d $Distribution -e cat $marker 2>$null | Out-String).Trim() -eq "42" } 30
    & wsl.exe -d $Distribution -e rm -f $marker
    if (-not $ran) { $failures += "the new session never ran a command at its prompt: $((Invoke-Ctl $state @("session", "text", "--target", $id)).result.text)" }
    Save-Snapshot $Shell "live-connected"
    Invoke-Ctl $state @("session", "close", "--target", $id) | Out-Null
    $failures
}

$failures = Invoke-ShellCase "wsl-ensure-live"
if ($failures) {
    Write-Host "FAIL wsl-server-gate: $($failures -join '; ')"
    exit 1
}
Write-Host "PASS wsl-server-gate ($Distribution connected)"
exit 0