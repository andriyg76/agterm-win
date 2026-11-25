param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
Get-AppxPackage -Name '*agterm*' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
Add-AppxPackage -Register -Path $ManifestPath
$pkg = Get-AppxPackage -Name '*agterm*' | Select-Object -First 1
if (-not $pkg) {
    Write-Error 'Package not registered'
}
$pkg | Format-List Name, Version, InstallLocation, PackageFamilyName