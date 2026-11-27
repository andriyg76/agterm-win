# Stages a self-contained agterm-win folder: the built exe and agtermctl, the native terminal core, the agterm version
# it is locked to with its server tarballs' sha256, zmx, and the Swift and MSVC runtime DLLs it loads, so it runs on a machine
# with no Swift toolchain (Windows Sandbox, a package).
param(
    [ValidateSet("debug", "release")][string]$Configuration = "debug",
    [Parameter(Mandatory)][string]$Output,
    [string]$SwiftRuntime,
    [string]$Version
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root ".build\$Configuration"
$agterm = Get-Content (Join-Path $root "AGTERM_VERSION") -TotalCount 1
if (-not $Version) { $Version = "$agterm.0" }
if ($Version -notmatch "^$([regex]::Escape($agterm))\.\d+$") { throw "Version must be $agterm.N, got $Version" }
foreach ($exe in "agterm-win.exe", "agtermctl.exe") {
    if (-not (Test-Path (Join-Path $build $exe))) { throw "build $Configuration first: no $build\$exe (swift build --product agtermctl builds the CLI)" }
}
if (-not $SwiftRuntime) {
    $runtimes = @((Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"), (Join-Path $env:ProgramFiles "Swift\Runtimes"))
    $latest = Get-ChildItem $runtimes -Directory -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    if (-not $latest) { throw "no Swift runtime under $($runtimes -join ', '); pass -SwiftRuntime" }
    $SwiftRuntime = Join-Path $latest.FullName "usr\bin"
}
if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
New-Item -ItemType Directory $Output | Out-Null
Copy-Item (Join-Path $build "agterm-win.exe"), (Join-Path $build "agtermctl.exe") $Output
Copy-Item (Join-Path $root "AGTERM_VERSION"), (Join-Path $root "vendor\server\agterm-server.sha256") $Output
$identity = [ordered]@{
    version = $Version
    buildDate = (Get-Item (Join-Path $build "agterm-win.exe")).LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
}
if ($env:GITHUB_ACTIONS -eq "true") {
    $branch = if ($env:GITHUB_HEAD_REF) { $env:GITHUB_HEAD_REF } else { $env:GITHUB_REF_NAME }
    if ($branch) { $identity.branch = $branch }
    if ($env:GITHUB_EVENT_NAME -in @("pull_request", "pull_request_target") -and $env:GITHUB_EVENT_PATH) {
        $event = Get-Content -Raw $env:GITHUB_EVENT_PATH | ConvertFrom-Json
        if ($event.pull_request.number) { $identity.pullRequest = [int]$event.pull_request.number }
    }
}
[IO.File]::WriteAllText((Join-Path $Output "build-info.json"), ($identity | ConvertTo-Json) + "`n")
# the bundled terminal themes, agterm's macOS names from iTerm2-Color-Schemes at the commit ghostty's themes pin, with its LICENSE
Copy-Item -Recurse (Join-Path $root "Resources\themes") (Join-Path $Output "themes")
# the Claude Code and Codex status adapters agterm-win installs into ~\.config\agterm\agent-status
Copy-Item -Recurse (Join-Path $root "Resources\agent-status") (Join-Path $Output "agent-status")
# the icon an installation outside the Store registers for its notifications
Copy-Item (Join-Path $root "Resources\agterm.png") $Output
# zmx goes to zmx\<version>-<sha12>, named by zmx\current: an upgrade adds a folder beside the one a running daemon holds open
$zmx = Join-Path $root "vendor\zmx"
if (Test-Path (Join-Path $zmx "zmx.exe")) {
    $version, $null, $sha256 = (Get-Content (Join-Path $zmx ".version")).Split(" ")
    $rev = "$version-$($sha256.Substring(0, 12))"
    $folder = Join-Path $Output "zmx\$rev"
    New-Item -ItemType Directory $folder | Out-Null
    Copy-Item (Join-Path $zmx "zmx.exe"), (Join-Path $zmx "LICENSE") $folder
    [IO.File]::WriteAllText((Join-Path $Output "zmx\current"), "$rev`n")
} else {
    Write-Warning "no vendor\zmx\zmx.exe (scripts\fetch-zmx.ps1); staged without zmx, so --local falls back to the source tree"
}
$ghosttyVT = Join-Path $root "vendor\ghostty-vt"
if (-not (Test-Path (Join-Path $ghosttyVT "LICENSE"))) {
    throw "no vendor\ghostty-vt (scripts\fetch-ghostty-vt.ps1); the native terminal core is required"
}
Copy-Item (Join-Path $ghosttyVT "LICENSE") (Join-Path $Output "libghostty-vt-LICENSE")
New-Item -ItemType Directory (Join-Path $Output "licenses") | Out-Null
Copy-Item -Recurse (Join-Path $ghosttyVT "licenses") (Join-Path $Output "licenses\libghostty-vt")
Get-ChildItem $build -Directory -Filter "*.resources" | % { Copy-Item -Recurse $_.FullName $Output }
Get-ChildItem $SwiftRuntime -Filter "*.dll" | % { Copy-Item $_.FullName $Output }
foreach ($dll in "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll") {
    $system = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $system) { Copy-Item $system $Output }
}
"staged $Output from $build with Swift runtime $SwiftRuntime"
