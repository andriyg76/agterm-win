# Installs MSVC -Toolset for -Arch into the runner's Visual Studio, hides every other MSVC version there and exports
# its vcvarsall environment to the job, so Swift's clang builds against that STL. windows-11-arm ships only Visual Studio 2026, whose MSVC 14.5x STL refuses
# the Clang 21 that Swift 6.4.3 carries; x64 gets the same toolset generation from windows-2022 instead.
#   scripts\use-msvc.ps1 -Toolset 14.43 -Component Microsoft.VisualStudio.Component.VC.14.43.17.13.ARM64 -Arch arm64
param(
    [Parameter(Mandatory)][string]$Toolset,
    [Parameter(Mandatory)][string]$Component,
    [ValidateSet("x64", "arm64")][string]$Arch = "arm64"
)
$ErrorActionPreference = "Stop"
$installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$vs = & "$installer\vswhere.exe" -latest -products * -property installationPath
if (-not $vs) { throw "no Visual Studio on this runner" }
"Visual Studio at $vs; adding $Component"
$setup = Start-Process "$installer\setup.exe" -Wait -PassThru -ArgumentList @(
    "modify", "--installPath", "`"$vs`"", "--add", $Component, "--quiet", "--norestart", "--nocache")
if ($setup.ExitCode -notin 0, 3010) { throw "the Visual Studio installer exited with $($setup.ExitCode)" }
$tools = Get-ChildItem "$vs\VC\Tools\MSVC" -Directory -Filter "$Toolset.*" | Sort-Object Name | Select-Object -Last 1
if (-not $tools) { throw "MSVC $Toolset is not under $vs\VC\Tools\MSVC after installing $Component" }
# swift build's build system takes the newest MSVC folder, whatever the environment or the default toolset file say;
# the runner is discarded after the job
Get-ChildItem "$vs\VC\Tools\MSVC" -Directory | Where-Object Name -ne $tools.Name |
    ForEach-Object { Rename-Item $_.FullName "hidden-$($_.Name)" }

$exported = "INCLUDE", "LIB", "LIBPATH", "PATH", "VCINSTALLDIR", "VCToolsInstallDir", "VCToolsVersion", "VCToolsRedistDir"
$environment = cmd /c "`"$vs\VC\Auxiliary\Build\vcvarsall.bat`" $Arch -vcvars_ver=$Toolset >nul && set"
if ($LASTEXITCODE) { throw "vcvarsall $Arch -vcvars_ver=$Toolset failed" }
foreach ($line in $environment) {
    $name = $line.Split("=", 2)[0]
    if ($exported -contains $name) { Add-Content $env:GITHUB_ENV $line }
}
"using MSVC $($tools.Name) for $Arch"
