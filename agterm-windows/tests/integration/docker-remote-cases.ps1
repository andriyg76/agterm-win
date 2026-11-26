# docker-remote: an Ubuntu container (docker-remote\Dockerfile) as a remote.properties remote reached by docker exec, so
# the defined-remote path is driven by something other than wsl.exe. Dot-sourced by shell-cases.ps1. It needs Docker
# running Linux containers and skips without them (run.ps1's ShellCaseSkipReason), as on GitHub's Windows runners.

$dockerRemoteName = "agterm-docker"
$dockerRemoteImage = "agterm-remote-test:gate"
$dockerRemoteUid = 2000
$dockerRemote = [pscustomobject]@{ Container = $null; Failure = $null }

function Invoke-Docker([string[]]$Arguments, [hashtable]$Environment = @{}) {
    $ErrorActionPreference = "Continue"
    $saved = @{}
    foreach ($key in $Environment.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, $Environment[$key]) }
    try { $out = (& docker.exe @Arguments 2>&1 | Out-String).Trim() } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function DockerRemoteSkipReason {
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) { return "no docker.exe on PATH" }
    $os = Invoke-Docker @("version", "--format", "{{.Server.Os}}")
    if ($os.Code -ne 0) { return "docker reaches no engine: $(@($os.Out -split "`n")[-1])" }
    if ($os.Out -ne "linux") { return "docker runs $($os.Out) containers; the case needs Linux containers" }
    $null
}

# Invoke-InContainer runs a shell line as the remote's user, with the remote's own environment. The line holds no double
# quote: Windows PowerShell passes one inside a native argument unescaped.
function Invoke-InContainer([string]$Line, [hashtable]$Environment = @{}) {
    $variables = @("-e", "XDG_RUNTIME_DIR=/run/user/$dockerRemoteUid") + @($Environment.Keys | % { "-e"; "$_=$($Environment[$_])" })
    Invoke-Docker (@("exec", "-u", "agterm", "-w", "/home/agterm") + $variables + @($dockerRemote.Container, "/bin/sh", "-c", $Line))
}

function Get-ServerZmxTree {
    $tree = Invoke-InContainer '$HOME/.local/bin/agtermctl zmx tree --json'
    if ($tree.Code -eq 0) { try { ($tree.Out | ConvertFrom-Json).result.remote } catch { $null } }
}

function Wait-ContainerBooted {
    Wait-Until {
        $state = (Invoke-Docker @("exec", $dockerRemote.Container, "systemctl", "is-system-running")).Out
        ($state -eq "running" -or $state -eq "degraded") -and (Invoke-InContainer "test -S /run/user/$dockerRemoteUid/systemd/private").Code -eq 0
    } 60
}

# The preparation builds the image, starts the container and installs agterm-server before the window starts, as a user
# would; a failure is the case's first finding. The container lives until the case's teardown, which runs either way.
$shellPreparations["docker-remote"] = {
    param($state)
    try {
        $dir = Split-Path $state
        $tty = Join-Path $dir "docker-tty.exe"
        Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot "docker-remote\DockerTty.cs") -Raw) -OutputAssembly $tty -OutputType ConsoleApplication

        $context = Join-Path $PSScriptRoot "docker-remote"
        $built = Invoke-Docker @("build", "-q", "-t", $dockerRemoteImage, $context)
        # over ssh the desktop credential helper has no logon session, and a public base image needs no credentials
        if ($built.Code -ne 0 -and $built.Out -match "error getting credentials") {
            $config = Join-Path $dir "docker-config"
            New-Item -ItemType Directory -Force $config | Out-Null
            $built = Invoke-Docker @("build", "-q", "-t", $dockerRemoteImage, $context) @{ DOCKER_CONFIG = $config }
        }
        if ($built.Code -ne 0) { throw "docker build failed: $($built.Out)" }

        # systemd as pid 1 needs its own writable cgroup tree and a tmpfs /run; no port is published
        $dockerRemote.Container = "agterm-remote-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $run = Invoke-Docker @("run", "-d", "--name", $dockerRemote.Container, "--hostname", "agterm-remote", "--privileged",
            "--cgroupns=private", "--tmpfs", "/run", "--tmpfs", "/run/lock", "--label", "agterm-remote-test", $dockerRemoteImage)
        if ($run.Code -ne 0) { $dockerRemote.Container = $null; throw "docker run failed: $($run.Out)" }
        if (-not (Wait-ContainerBooted)) { throw "the container's systemd and user manager did not come up within 60 s" }

        # docker exec starts no login session, so the remote's command supplies the XDG_RUNTIME_DIR ssh gets from PAM and
        # wsl.exe sets itself; without it systemctl --user fails: "Failed to connect to bus: No medium found"
        $config = Join-Path $state "config"
        New-Item -ItemType Directory -Force $config | Out-Null
        $line = "$dockerRemoteName = `"$($tty -replace '\\', '\\')`" exec -i -u agterm -w /home/agterm " +
            "-e XDG_RUNTIME_DIR=/run/user/$dockerRemoteUid $($dockerRemote.Container)"
        [IO.File]::WriteAllText((Join-Path $config "remote.properties"), "# seeded by the docker-remote case`n$line`n")

        $ErrorActionPreference = "Continue"
        $env:AGTERM_STATE_DIR = $state
        try { $install = (& $ctl server install $dockerRemoteName 2>&1 | Out-String).Trim(); $code = $LASTEXITCODE } finally { Remove-Item Env:AGTERM_STATE_DIR }
        Set-Content (Join-Path $dir "server-install.txt") $install
        Note "server install exited $code"
        if ($code -ne 0 -and $code -ne 3) { throw "agtermctl server install $dockerRemoteName exited $code`: $install" }
    } catch {
        $dockerRemote.Failure = "preparation: $($_.Exception.Message)"
    }
}
$shellLaunches["docker-remote"] = @{ Minimized = $true }
$shellCaseLimits["docker-remote"] = 420
$shellTeardowns["docker-remote"] = {
    param($Shell)
    if ($dockerRemote.Container) {
        Invoke-Docker @("logs", "--tail", "200", $dockerRemote.Container) | % { Set-Content (Join-Path $Shell.Dir "container.log") $_.Out }
        Invoke-Docker @("rm", "-f", $dockerRemote.Container) | Out-Null
    }
    Invoke-Docker @("rmi", $dockerRemoteImage) | Out-Null
}

# Wait-SessionText waits for the session's screen to match, and returns it.
function Wait-SessionText([string]$State, [string]$Id, [string]$Pattern, [int]$Seconds = 30) {
    Wait-Until { $text = "$((Invoke-Ctl $State @("session", "text", "--target", $Id)).result.text)"; if ($text -match $Pattern) { $text } } $Seconds
}

# New-DockerSession makes a session on the remote and waits for its shell's prompt, returning its id or a failure.
function New-DockerSession([string]$State) {
    $created = Invoke-Ctl $State @("session", "new", "--remote", $dockerRemoteName)
    if (-not $created.ok) { return [pscustomobject]@{ Failure = "session new --remote replied $($created | ConvertTo-Json -Compress)" } }
    $id = $created.result.id
    $node = Wait-Until { Get-Node $State $id } 30
    if (-not $node) { return [pscustomobject]@{ Failure = "session $id never showed in the tree" } }
    if ($node.remoteHost -ne $dockerRemoteName) { return [pscustomobject]@{ Failure = "session $id reads remoteHost '$($node.remoteHost)'" } }
    if (-not (Wait-SessionText $State $id 'agterm@agterm-remote:\S*\$')) {
        return [pscustomobject]@{ Failure = "no shell prompt in session $id`: $((Invoke-Ctl $State @("session", "text", "--target", $id)).result.text)" }
    }
    [pscustomobject]@{ Id = $id; Failure = $null }
}

# Get-DockerRemoteWindow is the remote's window as window list reports it.
function Get-DockerRemoteWindow([string]$State) {
    (Invoke-Ctl $State @("window", "list")).result.windows | ? { $_.remote.host -eq $dockerRemoteName } | Select-Object -First 1
}

$shellCases["docker-remote"] = {
    param($Shell)
    $state = $Shell.State
    if ($dockerRemote.Failure) { return @($dockerRemote.Failure) }
    $failures = @()

    # the window stays minimized throughout, so the pty checks below also cover panes made while it is
    $window = [AgtermWin32]::Owned($Shell.Process.Id, "agterm-shell", $false) | Select-Object -First 1
    if (-not $window -or -not [AgtermWin32]::IsIconic($window)) { $failures += "the window did not start minimized" }

    $opened = Invoke-Ctl $state @("window", "remote", "open", $dockerRemoteName)
    if (-not $opened.ok) { return @("window remote open replied $($opened | ConvertTo-Json -Compress)") }
    if (-not (Wait-Until { $w = Get-DockerRemoteWindow $state; $w.open -and $w.remote.state -eq "connected" } 60)) {
        return @("$dockerRemoteName did not connect: $((Invoke-Ctl $state @("window", "list")).result.windows | ConvertTo-Json -Compress -Depth 4)")
    }
    Note "connected"

    $session = New-DockerSession $state
    if ($session.Failure) { return @($session.Failure) }
    $id = $session.Id
    Note "session $id at a prompt"

    # the pane's attach must hold a pty sized by the window, not docker exec's pipes
    $nonce = [guid]::NewGuid().ToString("N").Substring(0, 8)
    # each answer carries a tag its echoed command line cannot match
    Invoke-Ctl $state @("session", "type", "--target", $id, "echo docker-$nonce-`$((6*7)) tty-`$(tty) size-`$(stty size | tr ' ' x)`r") | Out-Null
    $text = Wait-SessionText $state $id "docker-$nonce-42"
    if (-not $text) { $failures += "the command's output did not come back" }
    elseif ($text -notmatch "tty-/dev/pts/\d+") { $failures += "the pane has no pty: $text" }
    elseif ($text -notmatch "size-[1-9]\d*x[1-9]\d*") { $failures += "the pane's pty has no size: $text" }
    else { Note "pane: $($Matches[0])" }
    Note "typed and read back"

    $tree = Get-ServerZmxTree
    $daemons = @($tree.sessions | ? { $_.id -eq $id } | % { $_.panes } | % { $_.daemon } | ? { $_ })
    if (-not $daemons) { $failures += "the server's zmx tree does not list session $id" }
    $closed = Invoke-Ctl $state @("session", "close", "--target", $id)
    if (-not $closed.ok) { $failures += "session close replied $($closed | ConvertTo-Json -Compress)" }
    foreach ($daemon in $daemons) {
        # the name reaches the probe through its environment, so the probe's own command line never matches it
        $gone = Wait-Until {
            (Invoke-InContainer 'for p in /proc/[0-9]*; do tr ''\0'' _ <$p/cmdline 2>/dev/null | grep -q -- $DAEMON && exit 1; done; test ! -S $DIR/$DAEMON' @{
                DAEMON = $daemon; DIR = $tree.endpoint.socketDirectory }).Code -eq 0
        } 20
        if (-not $gone) { $failures += "daemon $daemon outlived session close" }
    }
    if ((Get-ServerZmxTree).sessions | ? { $_.id -eq $id }) { $failures += "the server still lists session $id after close" }
    Note "closed; daemons gone"

    # a defined remote gets no -L forward, so a page or link to the server's loopback opens at Windows' own port; WSL2
    # shares it with Windows, a container does not, so that is recorded as this remote's limit rather than asserted
    Invoke-Docker @("exec", "-d", "-u", "agterm", $dockerRemote.Container, "python3", "-m", "http.server", "8099", "--bind", "127.0.0.1") | Out-Null
    $served = Wait-Until { (Invoke-InContainer "bash -c 'exec 3<>/dev/tcp/127.0.0.1/8099'").Code -eq 0 } 15
    $ErrorActionPreference = "Continue"
    & "$env:SystemRoot\System32\curl.exe" --silent --max-time 5 --output NUL "http://127.0.0.1:8099/" 2>$null
    $reached = $LASTEXITCODE -eq 0
    Note ("limit: the container's 127.0.0.1:8099 (served: $([bool]$served)) is " + $(if ($reached) { "reachable" } else { "not reachable" }) + " from Windows")
    Set-Content (Join-Path $Shell.Dir "loopback.txt") "served in container: $([bool]$served); reachable from Windows: $reached"

    $stopped = Invoke-Docker @("stop", "-t", "15", $dockerRemote.Container)
    if ($stopped.Code -ne 0) { return $failures + @("docker stop failed: $($stopped.Out)") }
    $down = Wait-Until { $w = Get-DockerRemoteWindow $state; if ($w -and $w.remote.state -ne "connected") { $w } } 60
    if (-not $down) { $failures += "the remote still reads connected 60 s after the container stopped" }
    $remote = (Get-DockerRemoteWindow $state).remote
    Note "container stopped; remote reads $($remote.state)"

    $started = Invoke-Docker @("start", $dockerRemote.Container)
    if ($started.Code -ne 0) { return $failures + @("docker start failed: $($started.Out)") }
    if (-not (Wait-ContainerBooted)) { return $failures + @("the restarted container did not boot") }
    $back = Wait-Until { (Get-DockerRemoteWindow $state).remote.state -eq "connected" } 90
    $remote = (Get-DockerRemoteWindow $state).remote
    if ($back) {
        Note "container restarted; reconnected"
        $again = New-DockerSession $state
        if ($again.Failure) { $failures += "after the restart: $($again.Failure)" }
        else { Invoke-Ctl $state @("session", "close", "--target", $again.Id) | Out-Null }
    } elseif (-not (Invoke-Ctl $state @("tree")).ok) {
        $failures += "the window stopped answering after the container restarted"
    } else {
        Note "container restarted; not reconnected within 90 s, remote reads $($remote.state)"
        Set-Content (Join-Path $Shell.Dir "reconnect.txt") "not reconnected: $($remote | ConvertTo-Json -Compress -Depth 4)"
    }
    Save-Snapshot $Shell "after-restart"
    $failures
}
