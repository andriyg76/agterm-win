# Fetches the pinned Microsoft.Web.WebView2 native SDK (headers + WebView2LoaderStatic) into vendor/webview2.
param([ValidateSet("x64", "arm64")][string]$Arch = "x64")
$ErrorActionPreference = "Stop"
$version = "1.0.2849.39"
$vendor = Join-Path $PSScriptRoot "..\vendor\webview2"
$include = Join-Path $vendor "include\WebView2.h"
$lib = Join-Path $vendor "lib\$Arch\WebView2LoaderStatic.lib"
if ((Test-Path $include) -and (Test-Path $lib)) { return }
$nupkg = Join-Path $env:TEMP "Microsoft.Web.WebView2.$version.nupkg"
$extract = Join-Path $env:TEMP "Microsoft.Web.WebView2.$version"
if (-not (Test-Path $nupkg)) {
    Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$version" -OutFile $nupkg
}
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
Expand-Archive -Path $nupkg -DestinationPath $extract -Force
$native = Join-Path $extract "build\native"
New-Item -ItemType Directory -Force (Split-Path $include) | Out-Null
Copy-Item (Join-Path $native "include\WebView2.h") $include -Force
New-Item -ItemType Directory -Force (Split-Path $lib) | Out-Null
Copy-Item (Join-Path $native "$Arch\WebView2LoaderStatic.lib") $lib -Force
Remove-Item -Recurse -Force $extract
Write-Host "webview2 $version ($Arch) in $vendor"