# Builds the pinned libghostty-vt source release for Windows -Arch. The paired dependency archive makes the Zig build
# offline after the two verified downloads. Output is an install tree under vendor\ghostty-vt.
param([ValidateSet("x64", "arm64")][string]$Arch = "x64")
$ErrorActionPreference = "Stop"
$version = "1.0.1"
$sourceHash = "333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa"
$depsHash = "91a4e10960a52bf5bf4b15aa2a2cddaff8a89d6cd903d3055bda4fd17de3356d"
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "vendor\ghostty-vt"
$stamp = Join-Path $target ".version"
$want = "$version $Arch"
if ((Test-Path $stamp) -and ((Get-Content $stamp -TotalCount 1) -eq $want) -and
    (Test-Path (Join-Path $target "bin\ghostty-vt.dll")) -and
    (Test-Path (Join-Path $target "lib\ghostty-vt.lib")) -and
    (Test-Path (Join-Path $target "include\ghostty\vt.h")) -and
    (Test-Path (Join-Path $target "licenses\third-party.json"))) {
    exit 0
}

$cache = Join-Path $root "build\deps"
$work = Join-Path $cache "ghostty-vt-$version-build"
$sourceArchive = Join-Path $cache "libghostty-vt-$version.tar.gz"
$depsArchive = Join-Path $cache "libghostty-vt-$version-deps.tar.gz"
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
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory $work | Out-Null
& tar.exe -xzf $sourceArchive -C $work
if ($LASTEXITCODE) { throw "extracting libghostty-vt source failed" }
& tar.exe -xzf $depsArchive -C $work
if ($LASTEXITCODE) { throw "extracting libghostty-vt dependencies failed" }

$source = Join-Path $work "libghostty-vt-$version"
$dependencies = Join-Path $work "libghostty-vt-$version-deps"
if (Test-Path $target) { Remove-Item -Recurse -Force $target }
Push-Location $source
try {
    & zig build --prefix $target --system $dependencies -Dtarget=$(@{ x64 = "x86_64"; arm64 = "aarch64" }[$Arch])-windows-gnu -Doptimize=ReleaseFast -Dcpu=baseline
    if ($LASTEXITCODE) { throw "building libghostty-vt failed" }
} finally {
    Pop-Location
}
if (-not (Test-Path (Join-Path $target "bin\ghostty-vt.dll")) -or
    -not (Test-Path (Join-Path $target "lib\ghostty-vt.lib")) -or
    -not (Test-Path (Join-Path $target "include\ghostty\vt.h"))) {
    throw "libghostty-vt build did not produce its Windows install tree"
}
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
"built libghostty-vt $version for $Arch from source"
