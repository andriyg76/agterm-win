# Builds the vendored zmx Windows port into vendor/zmx (zmx.exe and its LICENSE), which --local panes attach through.
# zmx and its complete Zig dependency closure are committed under third-party, so this build performs no network access.
# Zig 0.17 comes from AGTERM_ZMX_ZIG, else from PATH.
$ErrorActionPreference = "Stop"
$rev = "be6bd9b7025fa7dfb4a37855c302ad2b7014933a"
$zig = if ($env:AGTERM_ZMX_ZIG) { $env:AGTERM_ZMX_ZIG } else { (Get-Command zig -ErrorAction Stop).Source }
$zigVersion = (& $zig version).Trim()
if (-not $zigVersion.StartsWith("0.17.")) { throw "zmx needs Zig 0.17, $zig is $zigVersion" }

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\zmx"
$stamp = Join-Path $target ".version"
$want = "$rev $zigVersion"
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $want) -and (Test-Path (Join-Path $target "zmx.exe"))) { exit 0 }

$source = Join-Path $root "third-party\zmx"
if (-not (Test-Path (Join-Path $source "build.zig")) -or -not (Test-Path (Join-Path $root "third-party\zmx-deps\ghostty"))) {
    throw "vendored zmx sources are incomplete under third-party"
}
Push-Location $source
try {
    # agterm panes export ZMX_NO_DETACH_KEY, and an upstream test that unsets it aborts Zig 0.17's test runner
    Remove-Item Env:ZMX_NO_DETACH_KEY -ErrorAction SilentlyContinue
    & $zig build -Doptimize=ReleaseSafe
    if ($LASTEXITCODE -ne 0) { throw "building zmx failed" }
    & $zig build test
    if ($LASTEXITCODE -ne 0) { throw "zmx tests failed" }
} finally {
    Pop-Location
}

if (Test-Path $target) { Remove-Item -Recurse -Force $target }
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item (Join-Path $source "zig-out\bin\zmx.exe"), (Join-Path $source "LICENSE") $target
Set-Content $stamp $want
