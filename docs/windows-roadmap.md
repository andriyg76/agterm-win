# agterm-win roadmap

Where agterm-win stands, what comes next, and how it should reach users.
Every item follows upstream agterm's behavior; see the [upstream parity rule](../AGENTS.md).

## What sets it apart

- **Wire-compatible with agterm.** The model, control protocol and `agtermctl` come from the shared `agtermCore`, so scripts, agent status hooks and the agent skill target one API on macOS, Linux and Windows.
- **WSL as the default remote.** Coding agents on Windows mostly run in WSL. agterm-win starts and installs agterm-server in a distribution from the sidebar, and those sessions keep running when the app closes.
- **Upstream agterm-server, unchanged.** The server in WSL is upstream's release build, checked against its published sha256, so server fixes arrive with each upstream version instead of being ported.
- **zmx on Windows.** [zmx-win](https://github.com/andriyg76/zmx-win) gives local Windows shells persistent sessions, the same daemon upstream uses for Live sessions on macOS.

## Shipped

- Native Win32 app for x64 and ARM64 with workspaces, sessions, splits, scratch, palettes, pick and ask dialogs, keymap and settings.
- Launch profiles: Windows PowerShell, PowerShell 7, Command Prompt, Git Bash, WSL distributions, and user profiles in `profiles.properties`.
- WSL agterm-server: start, install and attach from the sidebar.
- `agtermctl` with the upstream control protocol, and agent status for Claude Code and Codex.
- Distribution: Microsoft Store, GitHub Releases installer and portable ZIP.

## Next

- **Remote hosts over ssh.** Reach `remotes.conf` hosts (another Mac in Live sessions mode, a Linux agterm-server) through WSL OpenSSH first, then Windows OpenSSH and plink. Design: [backlog note](backlog/agterm-win-remote-hosts-over-ssh.md).
- **Package managers.** Chocolatey `agterm-win` is in moderation; submit the winget manifest that `scripts\package-managers.ps1` renders.
- **Code signing.** Sign the GitHub installer through SignPath Foundation, as the [packaging guide](../agterm-windows/packaging/README.md#code-signing-policy) describes, so SmartScreen stops warning.
- **WSL lifetime.** Confirm whether a distribution, and its sessions, stops after agterm-win quits. Analysis: [backlog note](backlog/wsl-distribution-may-stop-when-agterm-win-quits.md).

## Planned

- **agterm-server for Windows.** A native Windows server, so upstream agterm on a Mac and agterm-linux attach to a Windows machine's sessions over ssh, as they attach to a Linux host today. It starts once the Windows client reaches parity with the WSL server.
- **zmx-win upstream.** Offer the Windows support to upstream zmx, so persistent Windows sessions are not tied to this fork.

## Reaching users

- **Clear entry points.** Give the GitHub repository a description and topics that state the positioning above, and give zmx-win a README of its own for people who need persistent Windows sessions without agterm.
- **Upstream listing.** Ask upstream agterm, in its Discussions, to list agterm-win in its README's Related projects beside agterm-linux and agwinterm.
- **Store first.** Lead announcements with the Microsoft Store badge, the install with no warnings.
- **Demo.** A short recording of agents in WSL sessions reporting status in the sidebar, driven by `agtermctl`; once the Windows server ships, a Mac driving agents on a Windows machine.
- **Communities.** Show the Windows agent workflow where Claude Code and Codex users meet, and announce zmx-win separately for terminal and tmux users.
- **Contributors.** Tag small, well-described issues `good first issue` so a first contribution has an obvious start.
- **Sponsorship.** Once the project has users and outside contributors, check it against open source programs such as GitHub Sponsors and Anthropic's Claude for Open Source.
