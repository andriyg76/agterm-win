---
worth: yes
where: agterm-windows/Sources/agterm-win/WSLTransport.swift, WSLHost.swift
added: 2026-11-25
---
# remote hosts over ssh in agterm-win: Windows OpenSSH, WSL OpenSSH, plink

agterm-win reaches only WSL distributions' agterm-servers; `remotes.conf` hosts (another Mac in Live sessions mode,
a Linux agterm-server) are a parity gap, so Attach Remote, New Remote Session and Open Remote Window are missing
from the ☰ menu and the command palette.
agtermCore already hands over complete ssh argv (`RemoteSession`, `SshConnectionPool`); `WSLTransport` keeps only its
last element, the remote shell line, and runs it under `wsl.exe`.
Every protocol above the line is transport-agnostic, so each runner is another way to execute that argv.

Runners, chosen per host:

- **WSL OpenSSH**: `wsl.exe -d <distro> -e ssh <argv…>`. Argv passes unchanged and ControlMaster works; keys,
  agent and `~/.ssh/config` are the distribution's. Likely first, with no agtermCore change.
- **Windows OpenSSH** (`ssh.exe`): no ControlMaster (no Unix sockets), so the pool needs a no-multiplex mode:
  `ControlPath=none`, `-O check/exit` treated as succeeded, one connection per channel. Uses the Windows agent
  and `%USERPROFILE%\.ssh\config`.
- **plink** (PuTTY): needs an argv translation, not a passthrough: no `-o` options, `-batch` for `BatchMode`,
  `-T`/`-t`, `-L` forwards, `-load` for a saved PuTTY session, Pageant for keys; no multiplexing, as above.

Needed besides the runners:

- reading `remotes.conf` through agtermCore's `Remotes`, with a way to name a host's runner (a per-line option or
  a setting), and the hosts in `NativeMenu` beside the WSL servers, which puts them in the palette;
- pane attach: `WSLHost.attachCommandLine` substitutes `placeholderHost`; a ssh host needs the full `-tt` argv
  quoted by `WindowsCommandLine.quoted`;
- probe and `server install` over the runner, now written against `wsl.exe` in `WSLHost`;
- port forwards (`RemoteSession.forwardCommand`) and paste/open copies over the same runner;
- `agtermctl` coverage matching the Mac (`zmx tree|attach HOST`, `session new --remote`, `window remote open`).

A jump host (`ProxyJump`, or plink's `-proxycmd`/saved-session proxy) stays the runner's configuration, not agterm's.
