# Unpacks the pinned WebView2 SDK NuGet package into windows/vendor/webview2 (headers and the loader).
$ErrorActionPreference = "Stop"
$version = "1.0.2903.40"
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\webview2"
$stamp = Join-Path $target ".version"
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $version)) { exit 0 }
if (Test-Path $target) { Remove-Item -Recurse -Force $target }
New-Item -ItemType Directory -Force $target | Out-Null
$zip = Join-Path $env:TEMP "webview2-$version.zip"
Invoke-WebRequest -UseBasicParsing "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$version" -OutFile $zip
Expand-Archive -Force $zip $target
Set-Content $stamp $version
