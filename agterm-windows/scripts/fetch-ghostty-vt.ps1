# Lays out the pinned libghostty-vt Windows release for -Arch as the SwiftPM static-library artifact bundle
# vendor\ghostty-vt.artifactbundle, and its licenses under vendor\ghostty-vt. The source and dependency archives
# are read only for the third-party license files the binary zip does not carry.
param([ValidateSet("x64", "arm64")][string]$Arch = "x64")
$ErrorActionPreference = "Stop"
$version = "1.0.1"
$sourceHash = "333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa"
$depsHash = "91a4e10960a52bf5bf4b15aa2a2cddaff8a89d6cd903d3055bda4fd17de3356d"
$cpu = @{ x64 = "x86_64"; arm64 = "aarch64" }[$Arch]
$binaryHash = @{
    x64   = "8e2eb9e1822e85d786b456c8beb86f49d09c318c91f0c2913f91e7ffa12cda29"
    arm64 = "cc61da5f968ea0b08639bdf019c6b7da46bad1d985774fd8a2de57af32862892"
}[$Arch]
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\ghostty-vt"
$bundle = Join-Path $root "vendor\ghostty-vt.artifactbundle"
$stamp = Join-Path $target ".version"
$want = "$version $Arch"
if ((Test-Path $stamp) -and ((Get-Content $stamp -TotalCount 1) -eq $want) -and
    (Test-Path (Join-Path $bundle "info.json")) -and
    (Test-Path (Join-Path $target "licenses\third-party.json"))) {
    exit 0
}

$cache = Join-Path $root "build\deps"
$work = Join-Path $cache "ghostty-vt-$version-build"
$sourceArchive = Join-Path $cache "libghostty-vt-$version.tar.gz"
$depsArchive = Join-Path $cache "libghostty-vt-$version-deps.tar.gz"
$binaryName = "ghostty-vt-$version-$cpu-windows-gnu"
$binaryArchive = Join-Path $cache "$binaryName.zip"
New-Item -ItemType Directory -Force $cache | Out-Null

function Get-Verified([string]$Name, [string]$Path, [string]$Expected) {
    if ((Test-Path $Path) -and ((Get-FileHash $Path -Algorithm SHA256).Hash -eq $Expected)) { return }
    Invoke-WebRequest -UseBasicParsing "https://release.files.ghostty.org/libghostty-vt/$version/$Name" -OutFile $Path
    $actual = (Get-FileHash $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected) {
        Remove-Item $Path
        throw "$Name is $actual, not the pinned $Expected"
    }
}

Get-Verified "libghostty-vt-$version.tar.gz" $sourceArchive $sourceHash
Get-Verified "libghostty-vt-$version-deps.tar.gz" $depsArchive $depsHash
Get-Verified "$binaryName.zip" $binaryArchive $binaryHash
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory $work | Out-Null
& tar.exe -xzf $sourceArchive -C $work
if ($LASTEXITCODE) { throw "extracting libghostty-vt source failed" }
& tar.exe -xzf $depsArchive -C $work
if ($LASTEXITCODE) { throw "extracting libghostty-vt dependencies failed" }

$source = Join-Path $work "libghostty-vt-$version"
$dependencies = Join-Path $work "libghostty-vt-$version-deps"
& tar.exe -xf $binaryArchive -C $work
if ($LASTEXITCODE) { throw "extracting libghostty-vt binaries failed" }
$binary = Join-Path $work $binaryName
foreach ($path in $target, $bundle) { if (Test-Path $path) { Remove-Item -Recurse -Force $path } }
$variant = Join-Path $bundle "$cpu-windows"
New-Item -ItemType Directory $variant, $target | Out-Null
Copy-Item -Recurse (Join-Path $binary "include") $variant
Copy-Item (Join-Path $binary "lib\ghostty-vt-static.lib") (Join-Path $variant "ghostty-vt.lib")
[IO.File]::WriteAllText((Join-Path $variant "include\module.modulemap"), "module GhosttyVTC {`n    header `"ghostty/vt.h`"`n    export *`n}`n")
$info = [ordered]@{
    schemaVersion = "1.0"
    artifacts = @{ GhosttyVT = [ordered]@{ type = "staticLibrary"; version = $version; variants = @([ordered]@{
        path = "$cpu-windows/ghostty-vt.lib"
        supportedTriples = @("$cpu-unknown-windows-msvc")
        staticLibraryMetadata = @{ headerPaths = @("$cpu-windows/include"); moduleMapPath = "$cpu-windows/include/module.modulemap" }
    }) } }
}
[IO.File]::WriteAllText((Join-Path $bundle "info.json"), ($info | ConvertTo-Json -Depth 8))
Copy-Item (Join-Path $source "LICENSE") (Join-Path $target "LICENSE")
$licenseRoot = Join-Path $target "licenses"
New-Item -ItemType Directory $licenseRoot | Out-Null
$thirdPartyPath = Join-Path $source "deps\libghostty-vt-third-party.json"
Copy-Item $thirdPartyPath (Join-Path $licenseRoot "third-party.json")
$thirdParty = Get-Content $thirdPartyPath -Raw | ConvertFrom-Json
foreach ($entry in $thirdParty.third_party | Where-Object { $_.use -eq "linked" }) {
    $package = if ($entry.kind -eq "vendored") { Join-Path $source $entry.path } else { Join-Path $dependencies $entry.hash }
    $destination = Join-Path $licenseRoot $entry.name
    foreach ($license in Get-ChildItem $package -File -Recurse | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE)' }) {
        $relative = $license.FullName.Substring($package.Length).TrimStart('\', '/')
        $copy = Join-Path $destination $relative
        New-Item -ItemType Directory -Force (Split-Path -Parent $copy) | Out-Null
        Copy-Item $license.FullName $copy
    }
}
[IO.File]::WriteAllText($stamp, "$want`n")
"staged libghostty-vt $version for $Arch"
