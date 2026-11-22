# Builds the pinned zmx Windows port into windows/vendor/zmx (zmx.exe and its LICENSE), which --local panes attach
# through. The port carries agterm's zmx patches as commits, so nothing is applied over the pin. Zig 0.17 comes
# from AGTERM_ZMX_ZIG, else from PATH.
$ErrorActionPreference = "Stop"
$repo = "https://github.com/andriyg76/zmx-win"
$rev = "be6bd9b7025fa7dfb4a37855c302ad2b7014933a"
$zig = if ($env:AGTERM_ZMX_ZIG) { $env:AGTERM_ZMX_ZIG } else { (Get-Command zig -ErrorAction Stop).Source }
$zigVersion = (& $zig version).Trim()
if (-not $zigVersion.StartsWith("0.17.")) { throw "zmx needs Zig 0.17, $zig is $zigVersion" }

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\zmx"
$stamp = Join-Path $target ".version"
$want = "$rev $zigVersion"
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $want) -and (Test-Path (Join-Path $target "zmx.exe"))) { exit 0 }

$build = Join-Path $env:TEMP "agterm-zmx-$($rev.Substring(0, 12))"
if (Test-Path $build) { Remove-Item -Recurse -Force $build }
git init -q $build
git -C $build remote add origin $repo
git -C $build fetch -q --depth 1 origin $rev
git -C $build -c advice.detachedHead=false checkout -q FETCH_HEAD
if ($LASTEXITCODE -ne 0) { throw "fetching zmx $rev failed" }
Push-Location $build
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
Copy-Item (Join-Path $build "zig-out\bin\zmx.exe"), (Join-Path $build "LICENSE") $target
Set-Content $stamp $want
Remove-Item -Recurse -Force $build
