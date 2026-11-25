# Shared by agterm-win's agent-status adapters, the Windows twins of agterm's macOS hook scripts. Windows
# PowerShell 5.1 compatible and ASCII only, since 5.1 reads a BOM-less script in the ANSI code page.
#
# agtermctl resolution, as agterm-agent-status.sh does it: $env:AGTERMCTL, else the path agterm-win wrote below
# at install, else agtermctl on PATH once that path is gone (an uninstalled or moved build).
$AgtermCtl = 'agtermctl' # agterm-win installs its agtermctl path here
if ($env:AGTERMCTL) { $AgtermCtl = $env:AGTERMCTL }
elseif (-not (Test-Path -LiteralPath $AgtermCtl -PathType Leaf)) { $AgtermCtl = 'agtermctl' }

# AgtermTarget is the session, socket and pane a call addresses, from the variables agterm gives each pane.
function Get-AgtermTarget {
    $target = @('--target', $env:AGTERM_SESSION_ID)
    if ($env:AGTERM_SOCKET) { $target += @('--socket', $env:AGTERM_SOCKET) }
    if ($env:AGTERM_PANE) { $target += @('--pane', $env:AGTERM_PANE) }
    return , $target
}

# Send-AgtermStatus runs `agtermctl session status STATE [FLAGS]` for this pane; output and failures are dropped,
# since a hook's stdout reaches the agent and a failure must never block it.
function Send-AgtermStatus([string[]] $StatusArgs, [string[]] $Target = (Get-AgtermTarget)) {
    try { & $AgtermCtl session status @StatusArgs @Target *> $null } catch { }
}

# Get-AgtermScreen is the pane's visible text, $null once the session or the app is gone.
function Get-AgtermScreen([string[]] $Target = (Get-AgtermTarget)) {
    try {
        $text = & $AgtermCtl session text @Target 2> $null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($text) -join "`n")
    } catch { return $null }
}

# Read-HookPayload is the hook's JSON on stdin, read only when stdin is not a console and for at most two seconds,
# so an inherited open pipe never holds the agent; $null when absent or unparseable.
function Read-HookPayload {
    try {
        if (-not [Console]::IsInputRedirected) { return $null }
        $read = [Console]::In.ReadToEndAsync()
        if (-not $read.Wait(2000) -or -not $read.Result) { return $null }
        return ConvertFrom-Json $read.Result
    } catch { return $null }
}

# Test-HookField is whether the payload has the field at all, null included.
function Test-HookField($Payload, [string] $Name) {
    return $null -ne $Payload -and ($Payload.PSObject.Properties.Name -contains $Name)
}
