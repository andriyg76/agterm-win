# Runs run.ps1 inside Windows Sandbox: an isolated desktop with no network, so the host stays usable meanwhile.
# Stage the app first (scripts/stage.ps1). Exit code is the guest's: 0 pass, 1 test failure, 2 guest setup failure;
# a missing result is an error, never a pass. A passing Sandbox shuts itself down; a failing one, or any with
# -KeepOpen, stays open for inspection and must be closed before another run.
param(
    [Parameter(Mandatory)][string]$App,
    [string]$OutputDirectory = (Join-Path $env:TEMP ("agterm-sandbox\" + (Get-Date).ToString("yyyyMMddTHHmmss"))),
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600,
    [ValidateRange(2048, 65536)][int]$MemoryInMB = 4096,
    [switch]$DisableVGpu,
    [switch]$KeepOpen,
    [switch]$PrepareOnly
)
$ErrorActionPreference = "Stop"
$App = (Resolve-Path $App).Path
if (-not (Test-Path (Join-Path $App "agterm-win.exe"))) { throw "no agterm-win.exe in $App; run scripts/stage.ps1" }
$sandbox = if (-not $PrepareOnly) {
    $command = Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue
    if (-not $command) { throw "enable Windows Sandbox (Containers-DisposableClientVM), restart, and open it once from Start" }
    if (Get-Process WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) {
        throw "close the running Windows Sandbox first"
    }
    $command.Source
}
if (Test-Path $OutputDirectory) { throw "output directory exists: $OutputDirectory" }
$payload = Join-Path $OutputDirectory "input"
$results = Join-Path $OutputDirectory "results"
New-Item -ItemType Directory $payload, $results | Out-Null
Copy-Item -Recurse $App (Join-Path $payload "app")
Copy-Item -Recurse $PSScriptRoot (Join-Path $payload "tests")
if (-not $KeepOpen) { Set-Content (Join-Path $payload "close-on-pass") "" }
# Sandbox's image has no WebView2 runtime: carry the host's, which agterm-win loads as a fixed-version one
$webview = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application" -Directory |
    ? { $_.Name -match '^\d+(\.\d+){3}$' } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $webview) { throw "no WebView2 runtime on the host to carry into the Sandbox" }
Copy-Item -Recurse $webview.FullName (Join-Path $payload "webview2")
$inputXml = [Security.SecurityElement]::Escape($payload)
$resultsXml = [Security.SecurityElement]::Escape($results)
$vgpu = if ($DisableVGpu) { "Disable" } else { "Enable" }
$configuration = Join-Path $OutputDirectory "agterm-tests.wsb"
@"
<Configuration>
  <MemoryInMB>$MemoryInMB</MemoryInMB>
  <vGPU>$vgpu</vGPU>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <MappedFolders>
    <MappedFolder><HostFolder>$inputXml</HostFolder><SandboxFolder>C:\AgtermInput</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$resultsXml</HostFolder><SandboxFolder>C:\AgtermResults</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\AgtermInput\tests\sandbox-guest.ps1</Command></LogonCommand>
</Configuration>
"@ | Set-Content $configuration -Encoding UTF8
"configuration: $configuration"
"results: $results"
if ($PrepareOnly) { return }
Start-Process $sandbox -ArgumentList "`"$configuration`""
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$resultFile = Join-Path $results "result.json"
while (-not (Test-Path $resultFile)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw "no result within $TimeoutSeconds s; the Sandbox may still be running. Evidence: $results" }
    Start-Sleep -Milliseconds 500
}
$result = Get-Content $resultFile -Raw | ConvertFrom-Json
Get-Content (Join-Path $results "stdout.log") -ErrorAction SilentlyContinue
if ($result.error) { "guest error: $($result.error)" }
exit $result.exitCode
