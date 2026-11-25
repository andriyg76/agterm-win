# Claude Code status adapter agterm-win installs, agterm-claude-status.sh's Windows twin: the argv is the status
# to set (`active --blink`, `completed --auto-reset`, `blocked`), rewritten by what the hook's JSON payload says.
#
# A worker agent started from inside a session (`claude -p` from a tool call) inherits the spawner's AGTERM_*
# variables, so its hooks would repaint the spawner's row. As on a Mac the answer comes from process ancestry: one
# agent between this hook and the pane means it is the pane's agent, a second means a worker, which stays silent.
# A consecutive run of one name counts once. Any unreadable ancestry reports, since a false silence has no symptom.
try {
    if (-not $env:AGTERM_SESSION_ID) { exit 0 }
    . (Join-Path $PSScriptRoot 'agterm-status-lib.ps1')

    # the agents agterm-claude-status.sh counts, the same list as its shell integration's AGTERM_AGENT_RE
    $agents = @('claude', 'codex', 'kimi', 'opencode', 'pi', 'gemini', 'cursor-agent', 'aider', 'crush', 'goose')
    function Get-AgentName($Process) {
        $name = [IO.Path]::GetFileNameWithoutExtension([string] $Process.Name).ToLowerInvariant()
        if ($agents -contains $name) { return $name }
        # node- and bun-hosted CLIs: npm's shim runs `node ...\@anthropic-ai\claude-code\cli.js`, so the package folder
        # names the agent where a Mac's argv[1] would
        if (@('node', 'bun', 'deno', 'python', 'python3') -contains $name -and $Process.CommandLine) {
            if ($Process.CommandLine -match '[\\/]@anthropic-ai[\\/]claude-code[\\/]') { return 'claude' }
            if ($Process.CommandLine -match '[\\/]@openai[\\/]codex[\\/]') { return 'codex' }
            if ($Process.CommandLine -match '^("[^"]*"|\S+)\s+"?([^"\s]+)') {
                $hosted = [IO.Path]::GetFileNameWithoutExtension($Matches[2]).ToLowerInvariant()
                if ($agents -contains $hosted) { return $hosted }
            }
        }
        return $null
    }
    try {
        $table = @{}
        foreach ($process in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop) {
            $table[[int] $process.ProcessId] = $process
        }
        $count = 0
        $previous = $null
        $id = [int] $table[[int] $PID].ParentProcessId
        for ($step = 0; $step -lt 12 -and $table.ContainsKey($id); $step++) {
            $process = $table[$id]
            $name = Get-AgentName $process
            if ($name) {
                if ($name -ne $previous) { $count++ }
                $previous = $name
            } else { $previous = $null }
            if ($count -gt 1) { exit 0 } # a second agent above mine: I am a worker
            if ([IO.Path]::GetFileNameWithoutExtension([string] $process.Name) -eq 'agterm-win') { break }
            $id = [int] $process.ParentProcessId
        }
    } catch { }

    $status = @($args)
    $payload = Read-HookPayload
    if ($payload) {
        if ($payload.agent_id) {
            if ($status[0] -eq 'active') { $status += '--if-idle' }
        } elseif ($status[0] -eq 'completed' -and $payload.hook_event_name -eq 'Stop') {
            # a running subagent, workflow or shell keeps the row working; --auto-reset would idle it on the next visit
            foreach ($task in @($payload.background_tasks)) {
                if ($task -and $task.status -eq 'running' -and @('subagent', 'workflow', 'shell') -contains $task.type) {
                    $status = @('active', '--blink')
                    break
                }
            }
        }
    }
    Send-AgtermStatus -StatusArgs $status
} catch { }
exit 0
