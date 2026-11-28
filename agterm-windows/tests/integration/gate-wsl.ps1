# The Windows gate's own WSL distribution (gate.ps1), so the gate never starts, installs into or stops a distribution someone
# works in. Only names starting with agterm-gate- are made or removed.
#   gate-wsl.ps1 -New <name> -App <staged app> -Cache <dir>   import Ubuntu LTS, boot systemd, install agterm-server
#   gate-wsl.ps1 -Remove <name>                               unregister it and delete its disk
#   gate-wsl.ps1 -RemoveStale                                 unregister every agterm-gate-* a killed run left behind
param(
    [string]$New,
    [string]$Remove,
    [switch]$RemoveStale,
    [string]$App,
    [string]$Cache = (Join-Path $env:LOCALAPPDATA "agterm-gate"),
    [string]$Release = "24.04"
)
$ErrorActionPreference = "Stop"
$prefix = "agterm-gate-"
$disks = Join-Path $Cache "distributions"

function Assert-GateName([string]$Name) {
    if ($Name -notmatch "^$([regex]::Escape($prefix))[A-Za-z0-9-]+$") { throw "refusing '$Name': not an $prefix* distribution" }
}

# wsl.exe lists in UTF-16, which PowerShell 5.1 reads with a NUL after every character
function Get-Distributions { @((& wsl.exe -l -q 2>$null | Out-String) -replace "`0", "" -split "`r?`n" | % { $_.Trim() } | ? { $_ }) }

function Invoke-Root([string]$Name, [string]$Line) {
    & wsl.exe -d $Name -u root -e /bin/sh -c $Line
    if ($LASTEXITCODE) { throw "as root in $Name exited $LASTEXITCODE`: $Line" }
}

function Remove-GateDistribution([string]$Name) {
    Assert-GateName $Name
    if ((Get-Distributions) -contains $Name) {
        & wsl.exe --terminate $Name 2>$null | Out-Null
        & wsl.exe --unregister $Name | Out-Null
        if ($LASTEXITCODE) { throw "wsl --unregister $Name exited $LASTEXITCODE" }
        Write-Host "unregistered $Name"
    }
    Remove-Item -Recurse -Force (Join-Path $disks $Name) -ErrorAction SilentlyContinue
}

# Get-Rootfs is Ubuntu's WSL rootfs for $Release, downloaded again only when Ubuntu publishes a new one
function Get-Rootfs {
    $base = "https://cloud-images.ubuntu.com/wsl/releases/$Release/current"
    $file = "ubuntu-$(@{ '22.04' = 'jammy'; '24.04' = 'noble' }[$Release])-wsl-amd64-wsl.rootfs.tar.gz"
    New-Item -ItemType Directory -Force $Cache | Out-Null
    $sums = (Invoke-WebRequest -UseBasicParsing "$base/SHA256SUMS").Content
    $line = @($sums -split "`n" | ? { $_ -match "\s\*?$([regex]::Escape($file))$" })
    if ($line.Count -ne 1) { throw "SHA256SUMS at $base lists no $file" }
    $expected = ($line[0] -split '\s+')[0].ToLowerInvariant()
    $path = Join-Path $Cache $file
    if (-not (Test-Path $path) -or (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() -ne $expected) {
        Write-Host "downloading $base/$file"
        Invoke-WebRequest -UseBasicParsing "$base/$file" -OutFile "$path.part"
        if ((Get-FileHash -Algorithm SHA256 "$path.part").Hash.ToLowerInvariant() -ne $expected) { throw "$file does not match SHA256SUMS" }
        Move-Item -Force "$path.part" $path
    }
    $path
}

if ($RemoveStale) {
    foreach ($name in Get-Distributions | ? { $_.StartsWith($prefix) }) { Remove-GateDistribution $name }
    exit 0
}
if ($Remove) { Remove-GateDistribution $Remove; exit 0 }
if (-not $New) { throw "pass -New, -Remove or -RemoveStale" }
Assert-GateName $New
if (-not $App) { throw "-New needs -App, whose agtermctl installs agterm-server" }
$ctl = Join-Path (Resolve-Path $App) "agtermctl.exe"
if ((Get-Distributions) -contains $New) { throw "$New already exists" }

$rootfs = Get-Rootfs
$disk = Join-Path $disks $New
New-Item -ItemType Directory -Force $disk | Out-Null
& wsl.exe --import $New $disk $rootfs --version 2
if ($LASTEXITCODE) { throw "wsl --import $New exited $LASTEXITCODE" }
# agterm-server runs only as a systemd user unit, so the distribution boots systemd and its user lingers, as in
# docker-remote\Dockerfile; the default user is that user, since the app's wsl.exe -d <name> runs as it
Invoke-Root $New @'
set -e
id agterm >/dev/null 2>&1 || useradd -m -u 2000 -s /bin/bash agterm
mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/agterm
printf '[boot]\nsystemd=true\n[user]\ndefault=agterm\n[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf
'@
& wsl.exe --terminate $New | Out-Null
$booted = $false
for ($try = 0; $try -lt 60 -and -not $booted; $try++) {
    $state = (& wsl.exe -d $New -u root -e systemctl is-system-running 2>$null | Out-String).Trim()
    $booted = $state -in @("running", "degraded") -and
              ((& wsl.exe -d $New -e /bin/sh -c 'systemctl --user show-environment >/dev/null 2>&1 && echo ok' 2>$null | Out-String).Trim() -eq "ok")
    if (-not $booted) { Start-Sleep -Seconds 1 }
}
if (-not $booted) { throw "$New did not boot systemd with agterm's user manager in 60 s ($state)" }

# the install the app itself runs, through a throwaway state directory that defines only this distribution
$state = Join-Path $Cache "install-$New"
New-Item -ItemType Directory -Force (Join-Path $state "config") | Out-Null
[IO.File]::WriteAllText((Join-Path $state "config\remote.properties"), "$New = wsl.exe -d $New -e`n")
$env:AGTERM_STATE_DIR = $state
$ErrorActionPreference = "Continue"
try { $install = (& $ctl server install $New 2>&1 | Out-String).Trim(); $code = $LASTEXITCODE }
finally { Remove-Item Env:AGTERM_STATE_DIR; Remove-Item -Recurse -Force $state -ErrorAction SilentlyContinue }
$ErrorActionPreference = "Stop"
Write-Host $install
# 3: installed, agent hooks incomplete, which nothing here uses
if ($code -ne 0 -and $code -ne 3) { throw "agtermctl server install $New exited $code" }
Write-Host "$New ready"
