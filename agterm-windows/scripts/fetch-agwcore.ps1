# Downloads agwinterm's emulator core, the C-ABI DLL the --native spike draws from, pinned by release and sha256.
$ErrorActionPreference = "Stop"
$release = "v0.20.13"
$file = "agwinterm_core-abi19.dll"
$sha256 = "51a20d572dee779db5ade0b5a01110ec3aa641b4450a552e430f81c8f3e8969f"
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\agwcore"
$dll = Join-Path $target $file
if ((Test-Path $dll) -and ((Get-FileHash $dll -Algorithm SHA256).Hash -eq $sha256)) { exit 0 }
New-Item -ItemType Directory -Force $target | Out-Null
Invoke-WebRequest -UseBasicParsing "https://github.com/yeroo/agwinterm/releases/download/$release/$file" -OutFile $dll
$actual = (Get-FileHash $dll -Algorithm SHA256).Hash
if ($actual -ne $sha256) {
    Remove-Item $dll
    throw "$file is $actual, not the pinned $sha256"
}
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/yeroo/agwinterm/$release/LICENSE" -OutFile (Join-Path $target "LICENSE")
