# Downloads the pinned zmx Windows port for -Arch into vendor\zmx (zmx.exe and its LICENSE), which --local panes
# attach through. zmx-win's windows-release workflow builds it on GitHub runners and publishes release v<version>;
# the sha256 pinned here, not the release's own zmx.sha256, is what the download must match. The port carries
# agterm's zmx patches as commits, so nothing is applied over the pin.
param([ValidateSet("x64", "arm64")][string]$Arch = "x64")
$ErrorActionPreference = "Stop"
$version = "1.0.1.1"
$sha256 = @{
    x64   = "b47fbb67c0796d83a5e70783aaac0ef315e0f3ec31f9e828b4485bef889a112f"
    arm64 = "ca6afd8c1bc5558ac89b993c0768f3047107e2feddde17529d0456b778d66546"
}[$Arch]
$release = "https://github.com/andriyg76/zmx-win/releases/download/v$version"

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\zmx"
$stamp = Join-Path $target ".version"
$want = "$version $Arch $sha256"
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $want) -and (Test-Path (Join-Path $target "zmx.exe"))) { exit 0 }

$download = Join-Path $env:TEMP "agterm-zmx-$version-$Arch"
if (Test-Path $download) { Remove-Item -Recurse -Force $download }
New-Item -ItemType Directory $download | Out-Null
$exe = Join-Path $download "zmx.exe"
Invoke-WebRequest -UseBasicParsing "$release/zmx-$Arch.exe" -OutFile $exe
Invoke-WebRequest -UseBasicParsing "$release/LICENSE" -OutFile (Join-Path $download "LICENSE")
$actual = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLowerInvariant()
if ($actual -ne $sha256) { throw "zmx-$Arch.exe from $release is $actual, not the pinned $sha256" }

if (Test-Path $target) { Remove-Item -Recurse -Force $target }
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item $exe, (Join-Path $download "LICENSE") $target
Set-Content $stamp $want
Remove-Item -Recurse -Force $download
