# agterm-win privacy policy

Effective 2026-11-23. Applies to agterm-win, the Windows build of agterm, however it is installed:
the Microsoft Store, winget, Chocolatey or the installer from this repository's releases.

## Summary

agterm-win collects nothing about you and sends nothing to its developer.
It has no account, no telemetry, no analytics, no crash reporting and no advertising.
Everything it stores stays on your computer, in files you can read, move or delete.

## Network access

agterm-win connects to the network only when you ask it to:

- **Installing agterm-server** (`agterm-win --install-server`) downloads the agterm-server release matching
  this build from GitHub (`github.com/umputun/agterm`) and checks it against a SHA-256 sealed into this build.
  GitHub sees an ordinary download request, under [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
- **Links** you open from the terminal go to your default browser; agterm-win does not fetch them itself.

agterm-win does not check for updates on its own. Store, winget and Chocolatey installs are updated by those
services under their own policies.

Programs you run inside agterm-win (shells, ssh, git, coding agents) use the network as they normally do.
agterm-win does not see, log or forward their traffic.

## What is stored on your computer

State is under `%USERPROFILE%\.local\state\agterm-win` and config under `%USERPROFILE%\.config\agterm`, the same for
the Store app and every other install, beside one registry key. `AGTERM_WIN_STATE_DIR` names another state folder,
which then holds the config in its `config` folder. agterm-win 0.44.1.11 and earlier kept both in
`%LOCALAPPDATA%\agterm-win`; the first start of a later version moves them while the new folders hold none, and ends
the Live sessions an older version started, removing their `zmx` folder.

| File | What it holds |
|---|---|
| `native.json` | Settings: theme, font and size, notification choices, window position and size, the default launch profile, whether each WSL distribution's agterm-server starts at launch, and the local sessions open at quit. Each session keeps its name, the command line it started with and the folder it was last in, so it can start there again. |
| `keymap.conf`, `profiles.properties`, `remote.properties`, `themes\` (config) | Your key bindings, launch profiles, WSL and remote hosts, and themes. agterm-win writes the keymap only when you choose Edit Keymap. |
| `windows\wsl-<distribution>.json` | How agterm-win last showed an agterm-server's sessions, so the sidebar fills at once on the next start. |
| `agterm-win.log` | A diagnostic log: start and stop, sessions opened and closed, the commands that started them, the title and text of notifications posted to a session, errors. It does not record what you type or what programs print. |
| `crash.log` | Written only when agterm-win crashes: the error and where it happened. |
| `HKCU\Software\Classes\AppUserModelId\andriyg76.agterm-win` (registry, installs outside the Store) | The name and icon Windows shows on agterm-win's notifications. |

Its sockets are in the state folder too, which Windows opens only to your account and administrators, and carry
nothing off the machine: `agterm-<id>.sock`, the control socket `agtermctl` talks to, and, with Settings ▸ General ▸
Restore sessions set to Live sessions, `z\<id>`, the sockets and logs of the `zmx` processes that keep each local
session's shell running between starts.

Terminal contents and scrollback stay in memory: they are not written to disk and are gone when a session
closes. With Live sessions, a `zmx` process per pane keeps its shell and screen in memory after agterm-win closes,
until you close the session, start agterm-win with Fresh shells, or sign out.

So that Claude Code and Codex can show their status in the sidebar, agterm-win installs status hooks on its first
start and after each update, as agterm on a Mac does. It copies its PowerShell status scripts to
`%USERPROFILE%\.config\agterm\agent-status`. It adds hook entries that run those scripts to
`%USERPROFILE%\.claude\settings.json` and, when Codex is installed, to `config.toml` in Codex's folder
(`CODEX_HOME`, else `%USERPROFILE%\.codex`). Each file it changes is first saved beside itself as `.bak`, and
everything else in it is kept. The scripts only report a status to agterm-win's own control socket.

Sessions served by agterm-server keep their state inside your WSL distribution, under the Linux account's
`~/.local/state/agterm`, where they keep running after agterm-win closes.

Local sessions started with `--local` are held by `zmx` processes on this computer until you close them or sign
out.

## Removing your data

Close agterm-win and delete `%USERPROFILE%\.local\state\agterm-win`, your config files in `%USERPROFILE%\.config\agterm`,
any `%LOCALAPPDATA%\agterm-win` an older version left, and on an install outside the Store the
`HKCU\Software\Classes\AppUserModelId\andriyg76.agterm-win` registry key. Uninstalling, the Store app included, leaves
these folders in place, since they are outside the package, so delete them yourself if you want nothing left behind. agterm-server's data in WSL is removed
with `~/.local/state/agterm` there, or with the distribution. The status hooks are removed by deleting
`%USERPROFILE%\.config\agterm\agent-status`, agterm-win's entries in `%USERPROFILE%\.claude\settings.json`, and the
block between the `agterm-win agent-status` markers in Codex's `config.toml`.

## Children

agterm-win is a developer tool. It is not directed at children and collects no data from anyone.

## Changes

Changes to this policy are made in this file, so its history is the record of every version.

## Contact

Questions about this policy: open an issue at https://github.com/andriyg76/agterm-win/issues.
