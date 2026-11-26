# Codex lifecycle hook agterm-win installs, agterm-codex-status.sh's Windows twin. The argv is the action:
# session-start, user-prompt-submit, pre-tool-use, post-tool-use, permission-request or stop.
#
# Codex fires PermissionRequest before Auto Review decides whether a person must approve, so that event alone would
# flag automatically reviewed tools. One watcher per pane reads the visible footer for an approval dialog instead,
# while Stop checks the final assistant message for a question.
#
# AGTERM_CODEX_WATCH_FILE, AGTERM_CODEX_WATCH_MAX_CHECKS and AGTERM_CODEX_WATCH_INTERVAL tune the watcher as on a Mac.
try {
    . "$PSScriptRoot\agterm-status-lib.ps1"

    function Test-Question([string] $Message) {
        $prose = New-Object System.Collections.Generic.List[string]
        $fenced = $false
        foreach ($line in $Message -split "`n") {
            if ($line -match '^\s*```') { $fenced = -not $fenced; continue }
            if (-not $fenced) { $prose.Add($line) }
        }
        $text = ($prose -join "`n") -replace '`[^`]*`', 'code'
        # a ? that opens quoted text ("? for shortcuts") ends no word; the openers include the curly quotes
        $open = '["''' + [char] 0x201C + [char] 0x2018 + '(\[*_]+'
        $close = '[\]"'')*_!' + [char] 0x2019 + [char] 0x201D + ']*'
        $text = [regex]::Replace($text, '(?m)(^|\s)(' + $open + ')\?', '$1$2')
        return [regex]::IsMatch($text, '[^\s]\?' + $close + '(\s|$)')
    }

    function Get-WatchFile([string] $Session, [string] $Pane) {
        if ($env:AGTERM_CODEX_WATCH_FILE) { return $env:AGTERM_CODEX_WATCH_FILE }
        $key = ("$Session-$Pane") -replace '[^A-Za-z0-9._-]', '_'
        return Join-Path ([IO.Path]::GetTempPath()) "agterm-codex-watch-$key"
    }

    function Get-Token([string] $File) {
        try { return [IO.File]::ReadAllText($File).Trim() } catch { return $null }
    }

    function Invoke-Watch([string] $Token, [string] $File, [int] $MaxChecks, [double] $Interval, [string[]] $Target) {
        $visible = $false
        for ($check = 0; $check -lt $MaxChecks; $check++) {
            if ((Get-Token $File) -ne $Token) { return }
            $screen = Get-AgtermScreen -Target $Target
            if ($null -eq $screen) { return }
            $footer = ((@($screen -split "`n") | Select-Object -Last 12) -join "`n").ToLowerInvariant()
            $prompt = $false
            foreach ($phrase in 'press enter to confirm', 'enter to submit answer', 'enter to submit all', 'allow command?') {
                if ($footer.Contains($phrase)) { $prompt = $true }
            }
            if ($prompt) {
                # a later lifecycle event may have replaced this watcher while the screen was read
                if (-not $visible) {
                    if ((Get-Token $File) -ne $Token) { return }
                    Send-AgtermStatus -StatusArgs @('blocked') -Target $Target
                }
                $visible = $true
            } else {
                # the dialog closed: a denied request fires no later hook, so working again is this watcher's to say
                if ($visible) { Send-AgtermStatus -StatusArgs @('active', '--blink') -Target $Target }
                $visible = $false
            }
            if ($Interval -gt 0) { Start-Sleep -Milliseconds ([int] ($Interval * 1000)) }
        }
    }

    function Start-Watcher([string] $File) {
        $token = "$PID-$(Get-Random)"
        [IO.File]::WriteAllText($File, $token)
        $maxChecks = 5400
        if ($env:AGTERM_CODEX_WATCH_MAX_CHECKS -match '^\d+$') { $maxChecks = [int] $env:AGTERM_CODEX_WATCH_MAX_CHECKS }
        $interval = 2
        if ($env:AGTERM_CODEX_WATCH_INTERVAL -match '^\d+(\.\d+)?$') { $interval = $env:AGTERM_CODEX_WATCH_INTERVAL }
        # the watcher inherits no environment through WMI, so it gets the socket explicitly
        $target = Get-AgtermTarget
        if (-not $env:AGTERM_SOCKET -and $env:AGTERM_STATE_DIR) { $target += @('--socket', (Join-Path $env:AGTERM_STATE_DIR 'agterm.sock')) }
        $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                  '__watch-blocked', $token, $File, $maxChecks, $interval, $AgtermCtl) + $target
        $line = 'powershell.exe ' + (($argv | ForEach-Object { '"' + ([string] $_ -replace '"', '\"') + '"' }) -join ' ')
        # created by WMI, outside any job the agent runs its hooks in and closes when the hook returns
        try {
            Import-Module "$PSHOME\Modules\CimCmdlets\CimCmdlets.psd1"
            $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16] 0 }
            $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -ErrorAction Stop `
                -Arguments @{ CommandLine = $line; ProcessStartupInformation = $startup }
            if ($created.ReturnValue -eq 0) { return }
        } catch { }
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ($line.Substring('powershell.exe '.Length))
    }

    $action = [string] $args[0]
    if ($action -eq '__watch-blocked') {
        if ($args.Count -ge 6) {
            $AgtermCtl = [string] $args[5]
            Invoke-Watch -Token $args[1] -File $args[2] -MaxChecks $args[3] -Interval $args[4] -Target @($args | Select-Object -Skip 6)
        }
        exit 0
    }
    if (-not $env:AGTERM_SESSION_ID -or -not $action) { exit 0 }

    $file = Get-WatchFile $env:AGTERM_SESSION_ID $(if ($env:AGTERM_PANE) { $env:AGTERM_PANE } else { 'left' })
    $payload = Read-HookPayload
    # Codex's memory consolidation thread reaches the working hooks but never a user Stop, so its events would leave the
    # pane active and replace the foreground watcher; it is ephemeral, so its transcript_path is null
    if (@('session-start', 'user-prompt-submit', 'pre-tool-use', 'post-tool-use') -contains $action -and
        (Test-HookField $payload 'transcript_path') -and $null -eq $payload.transcript_path) { exit 0 }

    switch ($action) {
        'session-start' {
            Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
            Send-AgtermStatus -StatusArgs @('idle')
        }
        'user-prompt-submit' {
            Send-AgtermStatus -StatusArgs @('active', '--blink')
            Start-Watcher $file
        }
        { $_ -eq 'pre-tool-use' -or $_ -eq 'post-tool-use' } { Send-AgtermStatus -StatusArgs @('active', '--blink') }
        # a candidate only: the watcher reports blocked if Codex then leaves an approval prompt on screen
        'permission-request' { Start-Watcher $file }
        'stop' {
            Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
            if ($payload -and $payload.last_assistant_message -is [string] -and (Test-Question $payload.last_assistant_message)) {
                Send-AgtermStatus -StatusArgs @('blocked')
            } else {
                Send-AgtermStatus -StatusArgs @('completed', '--auto-reset')
            }
        }
    }
} catch { }
exit 0
