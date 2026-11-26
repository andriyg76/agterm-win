# Unsigned Inno installer + Store MSIX (and registerable layout) from an existing release build.
# CI runs swift build -c release first, then:
#   scripts\package-ci.ps1 -Version (Get-Content AGTERM_VERSION -TotalCount 1).0 -Arch x64 -Output $env:RUNNER_TEMP\ci-packages
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet("x64", "arm64")][string]$Arch = "x64",
    [Parameter(Mandatory)][string]$Output
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$agterm = Get-Content (Join-Path $root "AGTERM_VERSION") -TotalCount 1
if ($Version -notmatch "^$([regex]::Escape($agterm))\.\d+$") { throw "VERSION must be $agterm.N, got $Version" }

$build = Join-Path $root ".build\release"
foreach ($exe in "agterm-win.exe", "agtermctl.exe") {
    if (-not (Test-Path (Join-Path $build $exe))) {
        throw "no $build\$exe; run swift build -c release and swift build -c release --product agtermctl"
    }
}

if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
New-Item -ItemType Directory -Force $Output | Out-Null

$stage = Join-Path $env:TEMP "agterm-release-stage-$Arch"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
& (Join-Path $PSScriptRoot "stage.ps1") -Configuration release -Output $stage -Version $Version
$zmxRev = (Get-Content (Join-Path $stage "zmx\current") -TotalCount 1).Trim()
if (-not $zmxRev) { throw "staged without zmx; run scripts\fetch-zmx.ps1 -Arch $Arch" }

$iscc = if ($env:AGTERM_ISCC) { $env:AGTERM_ISCC } else { "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
if (-not (Test-Path $iscc)) { throw "no ISCC at $iscc; install Inno Setup 6" }
& $iscc /DAppVersion=$Version /DArch=$Arch /DStage=$stage /DOutput=$Output /DZmxRev=$zmxRev (Join-Path $root "packaging\agterm.iss")
if ($LASTEXITCODE) { throw "ISCC failed" }

& (Join-Path $PSScriptRoot "msix.ps1") -Version $Version -Arch $Arch -Stage $stage -Output $Output
& (Join-Path $PSScriptRoot "msix.ps1") -Version $Version -Arch $Arch -Stage $stage -Output $Output -LayoutOnly
"packaged installer and MSIX under $Output"