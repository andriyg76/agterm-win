# Builds, signs and packages an agterm-win release locally, and with -Publish uploads it to this fork's GitHub
# releases. VERSION is AGTERM_VERSION plus a Windows build number (0.44.0 -> 0.44.0.1, 0.44.0.2, ...).
#   scripts\release.ps1 -Version 0.44.0.1 [-Arch x64|arm64] [-Publish]
# -Arch is what the binaries are built for; Swift builds natively, so it is the host's architecture.
# Signing, one of:
#   AGTERM_SIGN_THUMBPRINT                         a code-signing certificate in the user's store (Certum SimplySign etc.)
#   AGTERM_SIGN_DLIB + AGTERM_SIGN_METADATA        Azure Trusted Signing's dlib and its metadata.json
# AGTERM_SIGN_TIMESTAMP overrides the RFC 3161 server. With neither, the build stops unless AGTERM_ALLOW_UNSIGNED=1,
# which makes an unsigned dry run (and an unsigned -Publish).
# Needs Inno Setup 6 (ISCC, or AGTERM_ISCC), the Windows SDK's signtool (or AGTERM_SIGNTOOL), Zig 0.17,
# 7-Zip for the DMG check (-SkipDmgCheck skips it), and gh for -Publish.
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet("x64", "arm64")][string]$Arch = "x64",
    [switch]$Publish,
    [switch]$SkipDmgCheck
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$agterm = Get-Content (Join-Path $root "AGTERM_VERSION") -TotalCount 1
if ($Version -notmatch "^$([regex]::Escape($agterm))\.\d+$") { throw "VERSION must be $agterm.N, got $Version" }
$out = Join-Path $root "build\release"
$stage = Join-Path $out "stage"

function Find-Tool($override, $pattern, $name) {
    if ($override) { return $override }
    $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($found) { return $found.FullName }
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "no $name; install it or set its AGTERM_ variable"
}

# ── signing ──────────────────────────────────────────────────────────────────
$timestamp = if ($env:AGTERM_SIGN_TIMESTAMP) { $env:AGTERM_SIGN_TIMESTAMP } else { "http://timestamp.digicert.com" }
$signArguments = if ($env:AGTERM_SIGN_THUMBPRINT) {
    @("/sha1", $env:AGTERM_SIGN_THUMBPRINT)
} elseif ($env:AGTERM_SIGN_DLIB -and $env:AGTERM_SIGN_METADATA) {
    if (-not $env:AGTERM_SIGN_TIMESTAMP) { $timestamp = "http://timestamp.acs.microsoft.com" }
    @("/dlib", $env:AGTERM_SIGN_DLIB, "/dmdf", $env:AGTERM_SIGN_METADATA)
} elseif ($env:AGTERM_ALLOW_UNSIGNED -eq "1") {
    Write-Warning "no signing identity: building UNSIGNED"
    $null
} else {
    throw "no signing identity (AGTERM_SIGN_THUMBPRINT or AGTERM_SIGN_DLIB + AGTERM_SIGN_METADATA); AGTERM_ALLOW_UNSIGNED=1 builds unsigned"
}
if ($signArguments) {
    $signtool = Find-Tool $env:AGTERM_SIGNTOOL "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" "signtool"
    $sign = @("sign", "/fd", "sha256", "/tr", $timestamp, "/td", "sha256") + $signArguments
}
$iscc = Find-Tool $env:AGTERM_ISCC "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" "ISCC"

# ── dependencies and build ───────────────────────────────────────────────────
foreach ($fetch in "fetch-server", "fetch-zmx", "fetch-ghostty-vt", "fetch-webview2") {
    if ($fetch -eq "fetch-server") { & (Join-Path $PSScriptRoot "$fetch.ps1") } else { & (Join-Path $PSScriptRoot "$fetch.ps1") -Arch $Arch }
}

# the sha256 the Mac app of the same release seals in, so a tarball replaced on GitHub since cannot pass
if (-not $SkipDmgCheck) {
    $sevenZip = Find-Tool $env:AGTERM_7Z "$env:ProgramFiles\7-Zip\7z.exe" "7z"
    $dmgDir = Join-Path $env:TEMP "agterm-dmg-$agterm"
    if (Test-Path $dmgDir) { Remove-Item -Recurse -Force $dmgDir }
    New-Item -ItemType Directory $dmgDir | Out-Null
    $dmg = Join-Path $dmgDir "agterm.dmg"
    Invoke-WebRequest -UseBasicParsing "https://github.com/umputun/agterm/releases/download/v$agterm/agterm-$agterm.dmg" -OutFile $dmg
    & $sevenZip x -y -r "-o$dmgDir\x" $dmg "agterm-server.sha256" | Out-Null
    $sealed = Get-ChildItem "$dmgDir\x" -Recurse -Filter "agterm-server.sha256" | Select-Object -First 1
    if (-not $sealed) { throw "no agterm-server.sha256 in agterm-$agterm.dmg; -SkipDmgCheck to release without the check" }
    $recorded = Join-Path $root "vendor\server\agterm-server.sha256"
    if (((Get-Content $sealed.FullName) -join "`n") -ne ((Get-Content $recorded) -join "`n")) {
        throw "vendor\server\agterm-server.sha256 differs from the one agterm $agterm's DMG seals"
    }
    Remove-Item -Recurse -Force $dmgDir
}

Push-Location $root
try {
    swift build -c release
    if ($LASTEXITCODE) { throw "swift build failed" }
    # agtermctl is agtermCore's product, which a root build does not build
    swift build -c release --product agtermctl
    if ($LASTEXITCODE) { throw "swift build --product agtermctl failed" }
} finally {
    Pop-Location
}
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
& (Join-Path $PSScriptRoot "stage.ps1") -Configuration release -Output $stage
$zmxRev = Get-Content (Join-Path $stage "zmx\current") -TotalCount 1 -ErrorAction SilentlyContinue
if (-not $zmxRev) { throw "the stage has no zmx" }

# ── sign, package ────────────────────────────────────────────────────────────
if ($signArguments) {
    $unsigned = Get-ChildItem $stage -Recurse -Include *.exe, *.dll | Where-Object { (Get-AuthenticodeSignature $_.FullName).Status -eq "NotSigned" }
    foreach ($file in $unsigned) {
        & $signtool @sign $file.FullName
        if ($LASTEXITCODE) { throw "signing $($file.Name) failed" }
    }
}
$defines = @("/DAppVersion=$Version", "/DArch=$Arch", "/DStage=$stage", "/DOutput=$out", "/DZmxRev=$zmxRev")
if ($signArguments) {
    $quoted = ($sign | ForEach-Object { if ($_ -match '\s') { "`$q$_`$q" } else { $_ } }) -join " "
    $defines += @("/DSign", "/Sagterm=`$q$signtool`$q $quoted `$f")
}
& $iscc @defines (Join-Path $root "packaging\agterm.iss")
if ($LASTEXITCODE) { throw "ISCC failed" }
$setup = Join-Path $out "agterm-win-$Version-$Arch-setup.exe"
$hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$setup.sha256", "$hash  $(Split-Path -Leaf $setup)`n")
"built $setup"

# ── publish ──────────────────────────────────────────────────────────────────
if (-not $Publish) { exit 0 }
$repo = (git -C $root remote get-url origin) -replace '^https://github\.com/', '' -replace '\.git$', ''
# the other architecture's run adds its installer to the release the first one created
gh release view "v$Version" --repo $repo *> $null
if (-not $LASTEXITCODE) {
    gh release upload "v$Version" $setup "$setup.sha256" --repo $repo
    if ($LASTEXITCODE) { throw "gh release upload failed" }
    exit 0
}
$notesPath = Join-Path $out "release-notes.md"
& (Join-Path $PSScriptRoot "release-notes.ps1") -Version $Version -OutFile $notesPath
Add-Content $notesPath @"

---

Windows 10 1809 or later, x64 or arm64. Installs per user, no admin.
"@
if (-not $signArguments) { Add-Content $notesPath "`nUNSIGNED: SmartScreen warns on first run." }
gh release create "v$Version" $setup "$setup.sha256" --repo $repo --title "agterm-win $Version" --notes-file $notesPath
if ($LASTEXITCODE) { throw "gh release create failed" }
