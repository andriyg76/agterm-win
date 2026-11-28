# agterm-win

[![Windows build](https://github.com/andriyg76/agterm-win/actions/workflows/windows.yml/badge.svg?branch=windows-port)](https://github.com/andriyg76/agterm-win/actions/workflows/windows.yml)

agterm-win is a native Windows terminal with a workspace and session sidebar and a scripting API. Run PowerShell, Command Prompt, and WSL side by side, and control sessions from scripts or coding agents with the bundled `agtermctl`. The Windows port of [agterm](https://github.com/umputun/agterm) shares the `agtermCore` session model with the upstream macOS app.

- **Wire-compatible with agterm.** The same control protocol and `agtermctl` as upstream, from the shared `agtermCore`, so scripts and agent integrations target one API on every platform.
- **WSL as the default remote.** Start agterm-server in a WSL distribution from the sidebar; its sessions keep running when the app closes. The server is upstream's release build, unchanged.
- **Persistent local sessions** on [zmx-win](https://github.com/andriyg76/zmx-win), a Windows port of the session daemon upstream agterm uses.

Next and planned work, including a native agterm-server for Windows that a Mac can attach to over ssh: [roadmap](docs/windows-roadmap.md).

## Install

<a href="https://get.microsoft.com/installer/download/9n0dd68bcxzx?referrer=appbadge" target="_self">
  <img src="https://get.microsoft.com/images/en-us%20dark.svg" width="200" alt="Get agterm-win from Microsoft Store" />
</a>

The Microsoft Store package supports **Windows 10 version 1903 or later** and is available for **x64 and ARM64**. Open **agterm-win** from the Start menu. The Store package makes `agtermctl` available as an app execution alias.

[GitHub Releases](https://github.com/andriyg76/agterm-win/releases/latest) also provides an installer and a portable ZIP for each architecture, for **Windows 10 version 1809 or later**. The installer sets up a per-user install without admin rights and adds `agtermctl` to your `PATH`. For the portable build, extract the ZIP and run `agterm-win.exe`, then run `agtermctl.exe` from the extracted folder or add the folder to your `PATH`. Neither is code-signed yet, so SmartScreen warns on first run.

## Work with sessions

- **Launch profiles.** Start Windows PowerShell, PowerShell 7, Command Prompt, Git Bash, or an installed WSL distribution, or add your own with **File ▸ Settings ▸ Edit Launch Profiles…**. The sidebar names sessions from the program title or working directory, and you can give a session a fixed name.
- **Panes and navigation.** Split a session, open a scratch shell, and switch between sessions with the session palette. See the [Windows keyboard shortcuts](docs/windows-shortcuts.md) for defaults and keymap details.
- **Persistent WSL sessions.** In the sidebar's new-session menu, choose **New Session Elsewhere → Start WSL Server** and pick a distribution. The app starts `agterm-server` inside that distribution, installing it when needed. Open a session on the server to keep its shell running when the Windows app closes.

## Script agterm-win

With agterm-win open, run these commands in PowerShell to create a session, list the sidebar tree and read the active session's terminal text.

```powershell
agtermctl session new
agtermctl tree --json
agtermctl session text
```

Use `agtermctl --help` to explore the CLI. The [upstream command reference](https://agterm.com/commands) and [cookbook](cookbook/) describe shared commands and workflows, including examples written for macOS.

## Documentation and support

- [Roadmap](docs/windows-roadmap.md): what is shipped, next and planned
- [Windows troubleshooting](docs/windows-troubleshooting.md): logs, state and config locations, common problems
- [Windows keyboard shortcuts](docs/windows-shortcuts.md)
- [Windows development and contributing](CONTRIBUTING.md#windows-development)
- [Windows packaging and releases](agterm-windows/packaging/README.md)
- [Privacy policy](agterm-windows/PRIVACY.md)
- [Report a Windows issue](https://github.com/andriyg76/agterm-win/issues)
- [Upstream agterm documentation](https://agterm.com/docs) for the macOS app and shared concepts

## Related projects

- [agterm](https://github.com/umputun/agterm) by [@umputun](https://github.com/umputun) is the upstream macOS app. agterm-win follows its features and behavior and merges its changes.
- [agterm-linux](https://github.com/melonamin/agterm-linux) by [@melonamin](https://github.com/melonamin) is the Linux port on the same `agtermCore`.
- [agwinterm](https://github.com/yeroo/agwinterm) by [@yeroo](https://github.com/yeroo) is an independent native Windows terminal inspired by agterm, and the reference for how the Windows UI looks and behaves.

## Attribution

agterm-win builds on upstream agterm: its `agtermCore` model, control API, `agtermctl`, and agent integrations come from there unchanged wherever Windows allows. Terminal emulation uses the VT engine of [Ghostty](https://github.com/ghostty-org/ghostty) (MIT), with native Windows rendering. Persistent sessions run on [zmx](https://github.com/andriyg76/zmx-win), a Windows fork of the session daemon upstream agterm bundles.

## License

agterm-win is licensed under the [MIT License](LICENSE).
