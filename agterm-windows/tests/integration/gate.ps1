# The Windows gate: the WSL and Docker cases hosted CI skips, run on a Windows box with WSL2 and Docker Linux containers
# against a build that already exists (docs/windows-gate.md). Run from a checkout of this repository:
#   gate.ps1 -Build v0.44.1.11            a release's x64 portable zip
#   gate.ps1 -Build 46158804275           a windows.yml run's ci-portable-x64 artifact (id or URL)
#   gate.ps1 -App <staged folder>         a local stage.ps1 output, with this checkout's cases
# The cases come from the build's own commit. Every case runs against a distribution of the gate's own (gate-wsl.ps1).
# Exit 0 when everything passed and nothing skipped; gate-summary.md under -Results is the line for the PR.
param(
    [string]$Build,
    [string]$App,
    [string[]]$Case = @("*"),
    [switch]$NoServerGate,
    [string]$Results = (Join-Path $env:TEMP "agterm-gate-results"),
    [string]$Repository = "andriyg76/agterm-win"
)
$ErrorActionPreference = "Stop"
if ([bool]$Build -eq [bool]$App) { throw "pass -Build or -App" }
$here = $PSScriptRoot
$work = Join-Path $env:TEMP "agterm-gate-work"
Remove-Item -Recurse -Force $work, $Results -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $Results | Out-Null

$failures = @()
$session = (Get-Process -Id $PID).SessionId
if ($session -eq 0) { $failures += "session 0 (a service) has no desktop for the cases" }
& wsl.exe --status *> $null
if ($LASTEXITCODE) { $failures += "wsl --status exited $LASTEXITCODE; WSL2 is not installed" }
$os = (& docker.exe version --format '{{.Server.Os}}' 2>&1 | Out-String).Trim()
if ($os -ne "linux") { $failures += "docker answers '$os', not linux containers" }
if ($Build -and -not (Get-Command gh -ErrorAction SilentlyContinue)) { $failures += "no gh on PATH to download $Build" }
if ($failures) { throw ($failures -join "; ") }

if ($Build) {
    $download = Join-Path $work "download"
    New-Item -ItemType Directory $download | Out-Null
    $Build = $Build.Trim()
    if ($Build -match '^(\d+)$' -or $Build -match 'actions/runs/(\d+)') {
        $run = $Matches[1]
        $info = gh api "repos/$Repository/actions/runs/$run" | ConvertFrom-Json
        if ($info.path -ne ".github/workflows/windows.yml") { throw "run $run is $($info.path), not windows.yml" }
        $sha = $info.head_sha
        gh run download $run -R $Repository -n ci-portable-x64 -D $download
        $label = "windows.yml run $run ($($info.head_branch) $($sha.Substring(0, 7)))"
    } else {
        $sha = (gh api "repos/$Repository/commits/$Build" | ConvertFrom-Json).sha
        gh release download $Build -R $Repository -p "*-x64-portable.zip" -D $download
        $label = "release $Build ($($sha.Substring(0, 7)))"
    }
    if ($LASTEXITCODE) { throw "download of $Build failed" }
    $zip = @(Get-ChildItem $download -Recurse -Filter "*-x64-portable.zip")
    if ($zip.Count -ne 1) { throw "expected one x64 portable zip, found $($zip.Count)" }
    $App = Join-Path $work "app"
    Expand-Archive $zip[0].FullName $App
    # the cases the build was made with, unpacked beside it rather than checked out over this tree
    & git -C $here fetch -q origin $sha
    if ($LASTEXITCODE) { throw "git fetch $sha failed" }
    $tree = Join-Path $work "tree"
    New-Item -ItemType Directory $tree | Out-Null
    & git -C $here archive -o (Join-Path $work "tests.zip") $sha agterm-windows/tests
    if ($LASTEXITCODE) { throw "git archive $sha failed" }
    Expand-Archive (Join-Path $work "tests.zip") $tree
    $cases = Join-Path $tree "agterm-windows\tests\integration"
} else {
    $App = (Resolve-Path $App).Path
    $sha = (& git -C $here rev-parse HEAD).Trim()
    $label = "local stage $App (checkout $($sha.Substring(0, 7)))"
    $cases = $here
}
# older cases start a server in the first distribution wsl -l lists, which may be someone's own
if (-not (Select-String -Quiet 'AGTERM_WIN_GATE_WSL' (Join-Path $cases "wsl-cases.ps1"))) {
    throw "the cases of $label predate the gate distribution and would reach a working one"
}

$distribution = "agterm-gate-$(Get-Date -Format yyyyMMddHHmmss)"
$env:AGTERM_WIN_GATE_WSL = $distribution
$lines = @()
$code = 1
try {
    & (Join-Path $here "gate-wsl.ps1") -RemoveStale
    & (Join-Path $here "gate-wsl.ps1") -New $distribution -App $App
    & (Join-Path $cases "run.ps1") -App $App -Results (Join-Path $Results "cases") -Case $Case
    $casesCode = $LASTEXITCODE
    $outcomes = @(Get-Content (Join-Path $Results "cases\cases.json") -Raw | ConvertFrom-Json)
    $failed = @($outcomes | ? { -not $_.passed })
    # run.ps1 counts a skip as a pass; the gate exists for the cases hosted CI skips
    $skipped = @($outcomes | ? { $_.skipped })
    $lines += "- run.ps1 ($($Case -join ', ')): $($outcomes.Count - $failed.Count - $skipped.Count) passed, $($failed.Count) failed, $($skipped.Count) skipped"
    $lines += @($failed | % { "  - FAIL ``$($_.name)``: $($_.failures -join '; ')" })
    $lines += @($skipped | % { "  - SKIP ``$($_.name)``: $($_.skipped)" })
    $serverCode = 0
    if (-not $NoServerGate) {
        & (Join-Path $cases "wsl-server-gate.ps1") -App $App -Results (Join-Path $Results "wsl-gate") -Distribution $distribution
        $serverCode = $LASTEXITCODE
        $lines += "- wsl-server-gate.ps1: $(if ($serverCode) { 'FAIL' } else { 'PASS' })"
    }
    $code = [int]($casesCode -or $skipped -or $serverCode)
} catch {
    $lines += "- gate stopped: $_"
} finally {
    Remove-Item Env:AGTERM_WIN_GATE_WSL
    & (Join-Path $here "gate-wsl.ps1") -Remove $distribution
}
$verdict = if ($code) { "FAIL" } else { "PASS" }
$summary = @("**Windows gate $verdict** on $label, $(Get-Date -Format 'yyyy-MM-dd HH:mm'), distribution $distribution") + $lines
$summary -join "`n" | Set-Content (Join-Path $Results "gate-summary.md") -Encoding UTF8
$summary | Write-Host
exit $code
