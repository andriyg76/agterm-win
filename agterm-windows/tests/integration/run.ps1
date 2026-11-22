# Integration cases against a staged agterm-win folder (scripts/stage.ps1). Each case launches the real window with
# its own state directory and reads the terminal's text back through AGTERM_WIN_TEST_SCREEN. It must run on an
# interactive desktop: the user's, or Windows Sandbox's through sandbox.ps1. Exit 0 when all pass, 1 otherwise.
param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Results,
    [ValidateRange(5, 600)][int]$CaseTimeoutSeconds = 60
)
$ErrorActionPreference = "Stop"
$exe = Join-Path (Resolve-Path $App) "agterm-win.exe"
if (-not (Test-Path $exe)) { throw "no agterm-win.exe in $App" }
New-Item -ItemType Directory -Force $Results | Out-Null
$Results = (Resolve-Path $Results).Path
$fixtures = Join-Path $PSScriptRoot "fixtures"

function Invoke-Case([string]$Name, [string]$Arguments) {
    $dir = Join-Path $Results $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $screen = Join-Path $dir "screen.txt"
    $env:AGTERM_WIN_STATE_DIR = Join-Path $dir "state"
    $env:AGTERM_WIN_TEST_SCREEN = $screen
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $Arguments -PassThru
    } finally {
        Remove-Item Env:AGTERM_WIN_STATE_DIR, Env:AGTERM_WIN_TEST_SCREEN
    }
    $timedOut = -not $process.WaitForExit($CaseTimeoutSeconds * 1000)
    if ($timedOut) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{
        Dir = $dir
        TimedOut = $timedOut
        Screen = if (Test-Path $screen) { Get-Content $screen -Raw -Encoding UTF8 } else { $null }
        Log = $(try { Get-Content (Join-Path $dir "state\agterm-win.log") -Raw -Encoding UTF8 } catch { "" })
    }
}

$cases = @(
    @{ Name = "local-exit-code"
       Arguments = "-- cmd.exe /d /c echo agterm-smoke-ok& exit /b 3"
       Expect = @("agterm-smoke-ok", "[process exited with code 3]") },
    @{ Name = "local-unicode"
       Arguments = "-- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtures\unicode.ps1"
       Expect = @(("smoke-" + (-join [char[]](0x043F, 0x0440, 0x0438, 0x0432, 0x0456, 0x0442)) + " " + [char]0x2713),
                  "[process exited with code 0]") }
)

$outcomes = foreach ($case in $cases) {
    $run = Invoke-Case $case.Name $case.Arguments
    $failures = @()
    if ($run.TimedOut) { $failures += "window did not close within $CaseTimeoutSeconds s" }
    if ($run.Log -notmatch "webview ready") { $failures += "webview never became ready" }
    if ($null -eq $run.Screen) { $failures += "no screen.txt" }
    else { foreach ($text in $case.Expect) { if (-not $run.Screen.Contains($text)) { $failures += "screen lacks '$text'" } } }
    $crash = Join-Path $run.Dir "state\crash.log"
    if (Test-Path $crash) { $failures += "crash: " + (Get-Content $crash -Raw).Trim() }
    $verdict = if ($failures) { "FAIL" } else { "PASS" }
    Write-Host ("{0} {1}{2}" -f $verdict, $case.Name, $(if ($failures) { ": " + ($failures -join "; ") } else { "" }))
    [pscustomobject]@{ name = $case.Name; passed = -not $failures; failures = $failures }
}
$failed = @($outcomes | ? { -not $_.passed }).Count
Write-Host "$($outcomes.Count - $failed) passed, $failed failed"
$outcomes | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Results "cases.json") -Encoding UTF8
exit [int]($failed -gt 0)
