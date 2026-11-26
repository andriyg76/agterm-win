# agterm-agent-status.ps1 - set the current agterm session's agent-status indicator, as agterm-agent-status.sh
# does on a Mac:
#
#   agterm-agent-status.ps1 active             # agent is busy
#   agterm-agent-status.ps1 completed          # agent finished a turn
#   agterm-agent-status.ps1 blocked --blink    # agent is waiting on you
#   agterm-agent-status.ps1 idle               # clear the indicator
#
# Further arguments go to `agtermctl session status` as they are. Outside agterm it does nothing, and as a hook it
# prints nothing and always exits 0.
try {
    if ($env:AGTERM_SESSION_ID) {
        . "$PSScriptRoot\agterm-status-lib.ps1"
        Send-AgtermStatus -StatusArgs @($args)
    }
} catch { }
exit 0
