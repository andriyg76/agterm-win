# Integration cases against a staged agterm-win folder (scripts/stage.ps1). Each case launches the real window with
# its own state directory: a command window's case reads the terminal's text back through AGTERM_WIN_TEST_SCREEN, a
# full window's case (shell-cases.ps1) drives it with agtermctl. It must run on an interactive desktop: the user's, or
# Windows Sandbox's through sandbox.ps1. Exit 0 when all pass, 1 otherwise.
param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Results,
    [ValidateRange(5, 600)][int]$CaseTimeoutSeconds = 60,
    # wildcard names of the cases to run, all when omitted
    [string[]]$Case = @("*"),
    # a pause after every step that changes the window, to watch a case run
    [ValidateRange(0, 30)][double]$StepSeconds = 0
)
$ErrorActionPreference = "Stop"
# `-Case` and loop locals must not share a name: PowerShell treats `$Case` and `$case` as one variable.
$casePatterns = @($Case)
if (-not $casePatterns.Count) { $casePatterns = @("*") }
$exe = Join-Path (Resolve-Path $App) "agterm-win.exe"
if (-not (Test-Path $exe)) { throw "no agterm-win.exe in $App" }
New-Item -ItemType Directory -Force $Results | Out-Null
$Results = (Resolve-Path $Results).Path
$fixtures = Join-Path $PSScriptRoot "fixtures"
. (Join-Path $PSScriptRoot "shell-cases.ps1")

function Write-Verdict([string]$Name, [string[]]$Failures) {
    $verdict = if ($Failures) { "FAIL" } else { "PASS" }
    Write-Host ("{0} {1}{2}" -f $verdict, $Name, $(if ($Failures) { ": " + ($Failures -join "; ") } else { "" }))
    [pscustomobject]@{ name = $Name; passed = -not $Failures; failures = $Failures }
}

# ShellCaseSkipReason skips a case on runners where it is known to fail for environmental reasons; see README.md.
function ShellCaseSkipReason([string]$Name) {
    $native = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
    if ($Name -eq "overlay-keys" -and $native -eq "ARM64") {
        return "arm64: Ctrl+W closes the session under a program overlay instead of dismissing the overlay (x64 passes; SendChord/GetFocus on windows-11-arm). Re-enable when fixed."
    }
    if ($Name -eq "docker-remote") { return DockerRemoteSkipReason }
    if ($Name -eq "remote-exit-buffer" -and -not $env:AGTERM_WIN_GATE_WSL) {
        return "set AGTERM_WIN_GATE_WSL for the remote exit-buffer GUI gate"
    }
    return $null
}

function Write-Skip([string]$Name, [string]$Reason) {
    Write-Host "SKIP $Name`: $Reason"
    [pscustomobject]@{ name = $Name; passed = $true; skipped = $Reason; failures = @() }
}

function Invoke-Case([string]$Name, [string]$Arguments) {
    $dir = Join-Path $Results $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $screen = Join-Path $dir "screen.txt"
    $env:AGTERM_WIN_STATE_DIR = Join-Path $dir "state"
    $env:AGTERM_WIN_TEST_SCREEN = $screen
    $process = Start-Process -FilePath $exe -ArgumentList $Arguments -PassThru
    $timedOut = -not $process.WaitForExit($CaseTimeoutSeconds * 1000)
    Remove-Item Env:AGTERM_WIN_STATE_DIR, Env:AGTERM_WIN_TEST_SCREEN -ErrorAction SilentlyContinue
    if ($timedOut) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{
        Dir = $dir
        TimedOut = $timedOut
        Screen = if (Test-Path $screen) { Get-Content $screen -Raw -Encoding UTF8 } else { $null }
        Log = $(try { Get-Content (Join-Path $dir "state\agterm-win.log") -Raw -Encoding UTF8 } catch { "" })
    }
}

$cases = @(
    @{ Name = "exit-code"
       Arguments = "-- cmd.exe /d /c echo agterm-native-ok& exit /b 3"
       Ready = "native: started"
       Expect = @("agterm-native-ok", "[process exited with code 3]") },
    @{ Name = "unicode"
       Arguments = "-- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtures\unicode.ps1"
       Ready = "native: started"
       Expect = @(("smoke-" + (-join [char[]](0x043F, 0x0440, 0x0438, 0x0432, 0x0456, 0x0442)) + " " + [char]0x2713),
                  "[process exited with code 0]") }
)

function Test-Selected([string]$Name) { [bool]($casePatterns | ? { $Name -like $_ }) }

$outcomes = foreach ($item in $cases | ? { Test-Selected $_.Name }) {
    $run = Invoke-Case $item.Name $item.Arguments
    $failures = @()
    if ($run.TimedOut) { $failures += "window did not close within $CaseTimeoutSeconds s" }
    if (-not $run.Log.Contains($item.Ready)) { $failures += "log lacks '$($item.Ready)'" }
    if ($null -eq $run.Screen) { $failures += "no screen.txt" }
    else { foreach ($text in $item.Expect) { if (-not $run.Screen.Contains($text)) { $failures += "screen lacks '$text'" } } }
    $crash = Join-Path $run.Dir "state\crash.log"
    if (Test-Path $crash) { $failures += "crash: " + (Get-Content $crash -Raw).Trim() }
    Write-Verdict $item.Name $failures
}
$outcomes = @($outcomes) + @(foreach ($name in @($shellCases.Keys) | ? { Test-Selected $_ }) {
    if ($skip = ShellCaseSkipReason $name) { Write-Skip $name $skip }
    else { Write-Verdict $name (Invoke-ShellCase $name) }
})
$failed = @($outcomes | ? { -not $_.passed }).Count
Write-Host "$($outcomes.Count - $failed) passed, $failed failed"
$outcomes | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Results "cases.json") -Encoding UTF8
exit [int]($failed -gt 0)
