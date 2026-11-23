$ErrorActionPreference = 'Stop'
# the OS's own architecture: an x64 PowerShell emulated on arm64 reports AMD64 in its environment
$native = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
$installer = if ($native -eq 'ARM64') { @{ Url = '{{UrlArm64}}'; Sha256 = '{{Sha256Arm64}}' } } else { @{ Url = '{{UrlX64}}'; Sha256 = '{{Sha256X64}}' } }
Install-ChocolateyPackage -PackageName $env:ChocolateyPackageName -FileType exe `
    -Url64bit $installer.Url -Checksum64 $installer.Sha256 -ChecksumType64 sha256 `
    -SilentArgs '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
