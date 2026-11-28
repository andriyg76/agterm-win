# agterm-win versions are major.minor.patch: major.minor is AGTERM_VERSION's (a line), patch counts agterm-win releases on it.
# A release runs from windows-port (master, incremental) or version/v<major>.<minor> (hotfix).
#   scripts\release-version.ps1 -Kind master|incremental|hotfix [-Branch <name>]   the next version and its base tag
#   scripts\release-version.ps1 -Version 0.44.2 [-Branch <name>]                   throws unless the branch may release it
param(
    [ValidateSet("master", "incremental", "hotfix")][string]$Kind,
    [string]$Version,
    [string]$Branch
)
$ErrorActionPreference = "Stop"
if ([bool]$Kind -eq [bool]$Version) { throw "pass -Kind or -Version" }
$root = Split-Path -Parent $PSScriptRoot
$agterm = Get-Content (Join-Path $root "AGTERM_VERSION") -TotalCount 1
$line = ($agterm -split '\.')[0..1] -join '.'
if (-not $Branch) { $Branch = git -C $root rev-parse --abbrev-ref HEAD }

$maintenance = $Branch -match '^version/v(\d+\.\d+)$'
if ($maintenance) {
    if ($Matches[1] -ne $line) { throw "$Branch releases $($Matches[1]).x, but AGTERM_VERSION is $agterm" }
} elseif ($Branch -ne "windows-port") {
    throw "releases run from windows-port or version/v<major>.<minor>, not $Branch"
} elseif (git -C $root ls-remote --heads origin "version/v$line") {
    throw "version/v$line owns the $line line; release it from there, or move AGTERM_VERSION to the next upstream minor"
}

if ($Version) {
    if ($Version -notmatch "^$([regex]::Escape($line))\.\d+$") { throw "VERSION must be $line.<patch>, got $Version" }
    exit 0
}

if ($Kind -eq "hotfix" -and -not $maintenance) { throw "hotfix runs from version/v<major>.<minor>, not $Branch" }
if ($Kind -ne "hotfix" -and $maintenance) { throw "$Kind runs from windows-port, not $Branch; $Branch takes hotfix" }

# a 4-part tag from before this scheme (v0.44.1.11) counts as the MSIX version it shipped as (0.44.1011),
# so the Store's package version never goes back
$base = git -C $root describe --tags --abbrev=0 --match "v[0-9]*" HEAD 2>$null
if ($base -notmatch '^v(\d+\.\d+)\.(\d+)(?:\.(\d+))?$') { throw "no release tag reachable from HEAD (got '$base')" }
$baseLine = $Matches[1]
$basePatch = if ($Matches[3]) { 1000 * [int]$Matches[2] + [int]$Matches[3] } else { [int]$Matches[2] }

$next = switch ($Kind) {
    "master" {
        if ([version]$line -le [version]$baseLine) {
            throw "master starts a line when AGTERM_VERSION moves past $baseLine; it is $agterm, so use incremental"
        }
        "$line.0"
    }
    default {
        if ($line -ne $baseLine) { throw "AGTERM_VERSION $agterm left the $baseLine line of $base; use master" }
        "$line.$($basePatch + 1)"
    }
}
if (git -C $root tag --list "v$next") { throw "v$next is already tagged" }
[pscustomobject]@{ Version = $next; Base = $base; BaseLine = $baseLine }
