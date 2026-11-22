# Builds an unsigned MSIX for Partner Center. The Store signs accepted packages.
param(
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][version]$Version,
    [Parameter(Mandatory)][string]$Publisher,
    [Parameter(Mandatory)][string]$PublisherDisplayName,
    [Parameter(Mandatory)][string]$StoreLogo,
    [Parameter(Mandatory)][string]$Square150x150Logo,
    [Parameter(Mandatory)][string]$Square44x44Logo
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$makeAppx = Get-Command makeappx.exe -ErrorAction Stop
$manifest = [xml](Get-Content (Join-Path $root "Package.appxmanifest") -Raw)
$identity = $manifest.Package.Identity
$identity.Publisher = $Publisher
$identity.Version = $Version.ToString(4)
$manifest.Package.Properties.PublisherDisplayName = $PublisherDisplayName
$manifest.Save((Join-Path $Stage "AppxManifest.xml"))
$assets = Join-Path $Stage "Assets"
New-Item -ItemType Directory -Force $assets | Out-Null
Copy-Item $StoreLogo (Join-Path $assets "StoreLogo.png")
Copy-Item $Square150x150Logo (Join-Path $assets "Square150x150Logo.png")
Copy-Item $Square44x44Logo (Join-Path $assets "Square44x44Logo.png")
& $makeAppx.Source pack /d $Stage /p $Output /o
if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed with exit code $LASTEXITCODE" }
Write-Output "Created unsigned Store MSIX at $Output. Upload it to Partner Center for signing."
