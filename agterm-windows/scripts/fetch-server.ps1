# Records the sha256 of the agterm-server tarballs of the agterm release this build is locked to (AGTERM_VERSION) into
# vendor\server\agterm-server.sha256, which `agterm-win --install-server` checks its download against, as the Mac app
# checks against the file release.sh seals into it. The tarballs are hashed here and not shipped.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$version = Get-Content (Join-Path $root "AGTERM_VERSION") -TotalCount 1
$target = Join-Path $root "vendor\server"
$checksums = Join-Path $target "agterm-server.sha256"
$stamp = Join-Path $target ".version"
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $version) -and (Test-Path $checksums)) { exit 0 }

$download = Join-Path $env:TEMP "agterm-server-$version"
if (Test-Path $download) { Remove-Item -Recurse -Force $download }
New-Item -ItemType Directory $download | Out-Null
$lines = foreach ($arch in "aarch64", "x86_64") {
    $name = "agterm-server-$version-linux-$arch.tar.gz"
    $path = Join-Path $download $name
    Invoke-WebRequest -UseBasicParsing "https://github.com/umputun/agterm/releases/download/v$version/$name" -OutFile $path
    "$((Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant())  $name"
}
New-Item -ItemType Directory -Force $target | Out-Null
# ServerInstall.checksum splits on LF and reads the name to the line's end, so no CRLF
[IO.File]::WriteAllText($checksums, ($lines -join "`n") + "`n")
Set-Content $stamp $version
Remove-Item -Recurse -Force $download
"recorded $checksums for agterm $version"
