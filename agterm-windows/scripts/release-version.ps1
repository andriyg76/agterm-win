# agterm-win versions are its own major.minor.patch, independent of AGTERM_VERSION (the upstream pin the build is locked to).
# windows-port releases any kind; version/v<major>.<minor> maintains a superseded line and releases only its patches.
# agterm-windows\VERSION holds the line as major.minor.0 for unreleased builds, so a line's first release is .1;
# a minor or major release rewrites it.
#   scripts\release-version.ps1 -Kind major|minor|incremental [-Branch <name>]   the next version and its base tag
#   scripts\release-version.ps1 -Version 0.44.1012 [-Branch <name>]             throws unless the branch may release it
param(
    [ValidateSet("major", "minor", "incremental")][string]$Kind,
    [string]$Version,
    [string]$Branch
)
$ErrorActionPreference = "Stop"
if ([bool]$Kind -eq [bool]$Version) { throw "pass -Kind or -Version" }
$root = Split-Path -Parent $PSScriptRoot
if (-not $Branch) { $Branch = git -C $root rev-parse --abbrev-ref HEAD }

# a 4-part tag from before this scheme (v0.44.1.11) counts as the MSIX version it shipped as (0.44.1011),
# so the Store's package version never goes back
$base = git -C $root describe --tags --abbrev=0 --match "v[0-9]*" HEAD 2>$null
if ($base -notmatch '^v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$') { throw "no release tag reachable from HEAD (got '$base')" }
$major, $minor = [int]$Matches[1], [int]$Matches[2]
$patch = if ($Matches[4]) { 1000 * [int]$Matches[3] + [int]$Matches[4] } else { [int]$Matches[3] }
$baseLine = "$major.$minor"
$versionFile = Join-Path $root "VERSION"
$stored = if (Test-Path $versionFile) { (Get-Content $versionFile -TotalCount 1).Trim() } else { "" }

$maintenance = $Branch -match '^version/v(\d+\.\d+)$'
if ($maintenance) {
    $line = $Matches[1]
    if ($line -ne $baseLine) { throw "$Branch maintains $line, but its last release is $base" }
} elseif ($Branch -ne "windows-port") {
    throw "releases run from windows-port or version/v<major>.<minor>, not $Branch"
}

if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION must be a.b.c, got $Version" }
    if ($maintenance -and $Version -notlike "$line.*") { throw "$Branch releases only $line.<patch>, not $Version" }
    $versionLine = ($Version -split '\.')[0..1] -join '.'
    if ($versionLine -ne $baseLine -and -not $Version.EndsWith(".1")) { throw "$Version skips the $versionLine line's first release, .1" }
    if ($stored -and $stored -ne "$versionLine.0") { throw "VERSION is $stored; set it to $versionLine.0 before releasing $Version" }
    exit 0
}

if ($stored -and $stored -ne "$baseLine.0") { throw "VERSION is $stored, but the last release $base is on the $baseLine line" }
if ($maintenance -and $Kind -ne "incremental") { throw "$Branch releases only incremental; $Kind runs from windows-port" }
# once a line has its maintenance branch, its patches come from there
if (-not $maintenance -and $Kind -eq "incremental" -and (git -C $root ls-remote --heads origin "version/v$baseLine")) {
    throw "version/v$baseLine maintains $baseLine; release its patch from there, or a minor or major from windows-port"
}

$next = switch ($Kind) {
    "major" { "$($major + 1).0.1" }
    "minor" { "$major.$($minor + 1).1" }
    "incremental" { "$major.$minor.$($patch + 1)" }
}
if (git -C $root tag --list "v$next") { throw "v$next is already tagged" }
[pscustomobject]@{ Version = $next; Base = $base; BaseLine = $baseLine; Latest = -not $maintenance; NewLine = $Kind -ne "incremental" }
