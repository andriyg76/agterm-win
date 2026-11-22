# Unpacks the pinned xterm.js and its fit addon from npm into vendor/xterm, so the page needs no network.
$ErrorActionPreference = "Stop"
$packages = [ordered]@{ "@xterm/xterm" = "5.5.0"; "@xterm/addon-fit" = "0.10.0" }
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\xterm"
$stamp = Join-Path $target ".version"
$version = ($packages.GetEnumerator() | % { "$($_.Key)@$($_.Value)" }) -join " "
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $version)) { exit 0 }
if (Test-Path $target) { Remove-Item -Recurse -Force $target }
New-Item -ItemType Directory -Force $target | Out-Null
foreach ($package in $packages.GetEnumerator()) {
    $name = $package.Key.Split("/")[1]
    $tarball = Join-Path $env:TEMP "$name-$($package.Value).tgz"
    $unpacked = Join-Path $env:TEMP "$name-$($package.Value)"
    Invoke-WebRequest -UseBasicParsing "https://registry.npmjs.org/$($package.Key)/-/$name-$($package.Value).tgz" -OutFile $tarball
    if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
    New-Item -ItemType Directory $unpacked | Out-Null
    tar.exe -xzf $tarball -C $unpacked
    if ($LASTEXITCODE) { throw "tar failed for $tarball" }
    Copy-Item (Join-Path $unpacked "package\lib\$name.js") $target
    if (Test-Path (Join-Path $unpacked "package\css\$name.css")) { Copy-Item (Join-Path $unpacked "package\css\$name.css") $target }
}
Set-Content $stamp $version
