# Stages a self-contained agterm-win folder: the built exe, the WebView2 loader, xterm.js, and the Swift and MSVC
# runtime DLLs it loads, so it runs on a machine with no Swift toolchain (Windows Sandbox, a package).
param(
    [ValidateSet("debug", "release")][string]$Configuration = "debug",
    [Parameter(Mandatory)][string]$Output,
    [string]$SwiftRuntime
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root ".build\$Configuration"
if (-not (Test-Path (Join-Path $build "agterm-win.exe"))) { throw "build $Configuration first: no $build\agterm-win.exe" }
if (-not $SwiftRuntime) {
    $runtimes = @((Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"), (Join-Path $env:ProgramFiles "Swift\Runtimes"))
    $latest = Get-ChildItem $runtimes -Directory -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    if (-not $latest) { throw "no Swift runtime under $($runtimes -join ', '); pass -SwiftRuntime" }
    $SwiftRuntime = Join-Path $latest.FullName "usr\bin"
}
if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
New-Item -ItemType Directory $Output | Out-Null
Copy-Item (Join-Path $build "agterm-win.exe") $Output
Copy-Item (Join-Path $root "vendor\webview2\build\native\x64\WebView2Loader.dll") $Output
Copy-Item -Recurse (Join-Path $root "vendor\xterm") (Join-Path $Output "xterm")
Get-ChildItem $build -Directory -Filter "*.resources" | % { Copy-Item -Recurse $_.FullName $Output }
Get-ChildItem $SwiftRuntime -Filter "*.dll" | % { Copy-Item $_.FullName $Output }
foreach ($dll in "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll") {
    $system = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $system) { Copy-Item $system $Output }
}
"staged $Output from $build with Swift runtime $SwiftRuntime"
