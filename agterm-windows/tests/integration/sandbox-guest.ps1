# Windows Sandbox logon command written by sandbox.ps1: runs run.ps1 on the guest desktop, leaves result.json, and
# shuts the Sandbox down after a pass unless the host asked to keep it.
param(
    [string]$InputDirectory = "C:\AgtermInput",
    [string]$ResultsDirectory = "C:\AgtermResults",
    [string]$WorkDirectory = "C:\AgtermTests"
)
$ErrorActionPreference = "Stop"
if ($env:USERNAME -ne "WDAGUtilityAccount") { throw "run sandbox.ps1 on the host; this runs inside Windows Sandbox" }
$exitCode = 2
$failure = $null
try {
    New-Item -ItemType Directory $WorkDirectory | Out-Null
    Get-ChildItem $InputDirectory -Force | % { Copy-Item $_.FullName $WorkDirectory -Recurse }
    $process = Start-Process powershell.exe -ArgumentList @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "$WorkDirectory\tests\run.ps1",
        "-App", "$WorkDirectory\app", "-Results", "$ResultsDirectory\cases"
    ) -RedirectStandardOutput "$ResultsDirectory\stdout.log" -RedirectStandardError "$ResultsDirectory\stderr.log" -Wait -PassThru
    $exitCode = $process.ExitCode
} catch {
    $failure = $_.ToString()
} finally {
    @{ exitCode = $exitCode; error = $failure } | ConvertTo-Json | Set-Content "$ResultsDirectory\result.json.tmp" -Encoding UTF8
    Move-Item "$ResultsDirectory\result.json.tmp" "$ResultsDirectory\result.json"
    if ($exitCode -eq 0 -and (Test-Path "$InputDirectory\close-on-pass")) { shutdown.exe /s /t 5 }
}
