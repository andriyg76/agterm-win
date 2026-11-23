$ErrorActionPreference = 'Stop'
# the installer is per user, so its uninstall entry is under HKCU, which Get-UninstallRegistryKey also searches
[array]$keys = Get-UninstallRegistryKey -SoftwareName 'agterm*' | Where-Object { $_.PSChildName -eq '{33086B3F-821D-4FAF-9EC9-F6490E82190B}_is1' }
foreach ($key in $keys) {
    Uninstall-ChocolateyPackage -PackageName $env:ChocolateyPackageName -FileType exe `
        -SilentArgs '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -File ($key.UninstallString -replace '"', '')
}
