# Renders packaging\winget and packaging\chocolatey for a published release into build\package-managers\<version>,
# taking the installer's sha256 from the release, and packs the Chocolatey .nupkg when choco is on PATH.
#   scripts\package-managers.ps1 -Version 0.44.1.1
# winget: the winget folder is the manifests/a/andriyg76/agterm-win/<version> directory of a microsoft/winget-pkgs PR.
# Chocolatey: choco push <nupkg> --source https://push.chocolatey.org/ with the account's API key.
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$repo = (git -C $root remote get-url origin) -replace '^https://github\.com/', '' -replace '\.git$', ''
$tag = "v$Version"
$release = gh release view $tag --repo $repo --json publishedAt | ConvertFrom-Json
if ($LASTEXITCODE) { throw "no release $tag in $repo" }
$sha256 = ((gh release download $tag --repo $repo --pattern "*.sha256" --output -) -split '\s+')[0].ToLowerInvariant()
if ($sha256 -notmatch '^[0-9a-f]{64}$') { throw "release $tag has no readable .sha256" }
$tokens = @{
    Version     = $Version
    Url         = "https://github.com/$repo/releases/download/$tag/agterm-win-$Version-x64-setup.exe"
    Sha256      = $sha256
    Sha256Upper = $sha256.ToUpperInvariant()
    ReleaseDate = ([datetime]$release.publishedAt).ToUniversalTime().ToString("yyyy-MM-dd")
}

$out = Join-Path $root "build\package-managers\$Version"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
$utf8 = New-Object System.Text.UTF8Encoding $false
foreach ($kind in "winget", "chocolatey") {
    $source = Join-Path $root "packaging\$kind"
    foreach ($file in Get-ChildItem $source -Recurse -File) {
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($name in $tokens.Keys) { $text = $text.Replace("{{$name}}", $tokens[$name]) }
        if ($text -match '\{\{\w+\}\}') { throw "$($file.Name) has an unknown token $($Matches[0])" }
        $target = Join-Path (Join-Path $out $kind) $file.FullName.Substring($source.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
        [IO.File]::WriteAllText($target, $text, $utf8)
    }
}
if (Get-Command choco -ErrorAction SilentlyContinue) {
    choco pack (Join-Path $out "chocolatey\agterm-win.nuspec") --out $out
    if ($LASTEXITCODE) { throw "choco pack failed" }
}
"rendered $out"
