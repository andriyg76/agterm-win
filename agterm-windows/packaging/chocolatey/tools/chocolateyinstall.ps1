$ErrorActionPreference = 'Stop'
Install-ChocolateyPackage -PackageName $env:ChocolateyPackageName -FileType exe `
    -Url64bit '{{Url}}' -Checksum64 '{{Sha256}}' -ChecksumType64 sha256 `
    -SilentArgs '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
