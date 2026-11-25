# Packs a stage.ps1 folder as the Microsoft Store's MSIX: packaging\msix\AppxManifest.xml, logos drawn from
# Resources\agterm.png, and MakeAppx. The Store signs the package; the .msix itself is unsigned and does not install.
#   scripts\msix.ps1 -Version 0.44.1.2 [-Arch x64|arm64] [-Stage build\release\stage] [-Output build\release] [-LayoutOnly]
#   [-Virtualized] uses packaging\msix\AppxManifest.store-virtualized.xml (Store-like, no unvirtualizedResources).
# Partner Center takes one .msix per architecture in the same submission and serves each device its own.
# -LayoutOnly stops at the folder, which Developer Mode registers with Add-AppxPackage -Register <folder>\AppxManifest.xml.
# The identity is what Partner Center reserved: AGTERM_MSIX_NAME, AGTERM_MSIX_PUBLISHER (its CN=...) and
# AGTERM_MSIX_PUBLISHER_NAME; the defaults serve only a local register. MakeAppx comes from AGTERM_MAKEAPPX or the Windows SDK.
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet("x64", "arm64")][string]$Arch = "x64",
    [string]$Stage,
    [string]$Output,
    [switch]$LayoutOnly,
    [switch]$Virtualized
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Output) { $Output = Join-Path $root "build\release" }
if (-not $Stage) { $Stage = Join-Path $Output "stage" }
if (-not (Test-Path (Join-Path $Stage "agterm-win.exe"))) { throw "no agterm-win.exe in $Stage (scripts\stage.ps1)" }

# the Store needs the fourth part 0, so agterm a.b.c and Windows build n become a.b.(1000c+n).0
if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)\.(\d+)$' -or [int]$Matches[4] -ge 1000 -or [int]$Matches[3] -ge 65) {
    throw "VERSION must be a.b.c.n with c < 65 and n < 1000, got $Version"
}
$packageVersion = "$($Matches[1]).$($Matches[2]).$(1000 * [int]$Matches[3] + [int]$Matches[4]).0"
$tokens = @{
    IdentityName         = if ($env:AGTERM_MSIX_NAME) { $env:AGTERM_MSIX_NAME } else { "andriyg76.agterm-win" }
    Publisher            = if ($env:AGTERM_MSIX_PUBLISHER) { $env:AGTERM_MSIX_PUBLISHER } else { "CN=andriyg76" }
    PublisherDisplayName = if ($env:AGTERM_MSIX_PUBLISHER_NAME) { $env:AGTERM_MSIX_PUBLISHER_NAME } else { "andriyg76" }
    Version              = $packageVersion
    Architecture         = $Arch
}

$layout = Join-Path $Output $(if ($Virtualized) { "msix-virtualized" } else { "msix" })
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
Copy-Item -Recurse $Stage $layout
$manifestName = if ($Virtualized) { "AppxManifest.store-virtualized.xml" } else { "AppxManifest.xml" }
$manifest = [IO.File]::ReadAllText((Join-Path $root "packaging\msix\$manifestName"))
foreach ($name in $tokens.Keys) { $manifest = $manifest.Replace("{{$name}}", [Security.SecurityElement]::Escape($tokens[$name])) }
[IO.File]::WriteAllText((Join-Path $layout "AppxManifest.xml"), $manifest, (New-Object System.Text.UTF8Encoding $false))

Add-Type -AssemblyName System.Drawing
$icon = [Drawing.Image]::FromFile((Join-Path $root "Resources\agterm.png"))
try {
    New-Item -ItemType Directory (Join-Path $layout "Assets") | Out-Null
    foreach ($logo in @{ "Square150x150Logo" = 150; "Square44x44Logo" = 44; "StoreLogo" = 50 }.GetEnumerator()) {
        $bitmap = New-Object Drawing.Bitmap $logo.Value, $logo.Value
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($icon, 0, 0, $logo.Value, $logo.Value)
        $graphics.Dispose()
        $bitmap.Save((Join-Path $layout "Assets\$($logo.Key).png"), [Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
    }
} finally {
    $icon.Dispose()
}
if ($LayoutOnly) { "laid out $layout ($packageVersion)"; exit 0 }

$makeappx = if ($env:AGTERM_MAKEAPPX) { $env:AGTERM_MAKEAPPX } else {
    Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $makeappx) { throw "no makeappx.exe; install the Windows SDK or set AGTERM_MAKEAPPX" }
$suffix = if ($Virtualized) { "-store-virtualized" } else { "" }
$package = Join-Path $Output "agterm-win-$Version-$Arch$suffix.msix"
& $makeappx pack /o /d $layout /p $package
if ($LASTEXITCODE) { throw "makeappx failed" }
"packed $package ($packageVersion)"
