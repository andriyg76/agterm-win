# Downloads the pinned zmx Windows port for -Arch into vendor\zmx (zmx.exe and its LICENSE), which --local panes
# attach through. zmx-win's windows-release workflow builds it on GitHub runners and publishes release win-<rev12>;
# the sha256 pinned here, not the release's own zmx.sha256, is what the download must match. The port carries
# agterm's zmx patches as commits, so nothing is applied over the pin.
param([ValidateSet("x64", "arm64")][string]$Arch = "x64")
$ErrorActionPreference = "Stop"
$rev = "014fa587f1a1e5c6f151999421a3252d213cc4dc"
$sha256 = @{
    x64   = "cc023db72677aa7ef42100774aff32476e94a6fa40c9e7c9763f03acbf859bc1"
    arm64 = "a345b2b44dc139983468fa7513e5dd8a758456320858b861b945fc38083eb209"
}[$Arch]
$release = "https://github.com/andriyg76/zmx-win/releases/download/win-$($rev.Substring(0, 12))"

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\zmx"
$stamp = Join-Path $target ".version"
$want = "$rev $Arch $sha256"
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $want) -and (Test-Path (Join-Path $target "zmx.exe"))) { exit 0 }

$download = Join-Path $env:TEMP "agterm-zmx-$($rev.Substring(0, 12))-$Arch"
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
