# Stages a self-contained agterm-win folder: the built exe and agtermctl, xterm.js, the agterm version it is
# locked to with its server tarballs' sha256, zmx, and the Swift and MSVC runtime DLLs it loads, so it runs on a machine
# with no Swift toolchain (Windows Sandbox, a package).
param(
    [ValidateSet("debug", "release")][string]$Configuration = "debug",
    [Parameter(Mandatory)][string]$Output,
    [string]$SwiftRuntime
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root ".build\$Configuration"
foreach ($exe in "agterm-win.exe", "agtermctl.exe") {
    if (-not (Test-Path (Join-Path $build $exe))) { throw "build $Configuration first: no $build\$exe (swift build --product agtermctl builds the CLI)" }
}
if (-not $SwiftRuntime) {
    $runtimes = @((Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"), (Join-Path $env:ProgramFiles "Swift\Runtimes"))
    $latest = Get-ChildItem $runtimes -Directory -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    if (-not $latest) { throw "no Swift runtime under $($runtimes -join ', '); pass -SwiftRuntime" }
    $SwiftRuntime = Join-Path $latest.FullName "usr\bin"
}
if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
New-Item -ItemType Directory $Output | Out-Null
Copy-Item (Join-Path $build "agterm-win.exe"), (Join-Path $build "agtermctl.exe") $Output
Copy-Item -Recurse (Join-Path $root "vendor\xterm") (Join-Path $Output "xterm")
Copy-Item (Join-Path $root "AGTERM_VERSION"), (Join-Path $root "vendor\server\agterm-server.sha256") $Output
# zmx goes to zmx\<rev>, named by zmx\current: an upgrade adds a folder beside the one a running daemon holds open
$zmx = Join-Path $root "vendor\zmx"
if (Test-Path (Join-Path $zmx "zmx.exe")) {
    $rev = (Get-Content (Join-Path $zmx ".version")).Split(" ")[0].Substring(0, 12)
    $folder = Join-Path $Output "zmx\$rev"
    New-Item -ItemType Directory $folder | Out-Null
    Copy-Item (Join-Path $zmx "zmx.exe"), (Join-Path $zmx "LICENSE") $folder
    [IO.File]::WriteAllText((Join-Path $Output "zmx\current"), "$rev`n")
} else {
    Write-Warning "no vendor\zmx\zmx.exe (scripts\fetch-zmx.ps1); staged without zmx, so --local falls back to the source tree"
}
$agwcore = Join-Path $root "vendor\agwcore"
if (Test-Path (Join-Path $agwcore "*.dll")) {
    Copy-Item (Join-Path $agwcore "*.dll") $Output
    Copy-Item (Join-Path $agwcore "LICENSE") (Join-Path $Output "agwinterm-core-LICENSE")
} else {
    Write-Warning "no vendor\agwcore (scripts\fetch-agwcore.ps1); staged without the --native spike's core"
}
Get-ChildItem $build -Directory -Filter "*.resources" | % { Copy-Item -Recurse $_.FullName $Output }
Get-ChildItem $SwiftRuntime -Filter "*.dll" | % { Copy-Item $_.FullName $Output }
foreach ($dll in "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll") {
    $system = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $system) { Copy-Item $system $Output }
}
"staged $Output from $build with Swift runtime $SwiftRuntime"
