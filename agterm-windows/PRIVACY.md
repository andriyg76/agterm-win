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

The files are under `%LOCALAPPDATA%\agterm-win`, or the folder `AGTERM_WIN_STATE_DIR` names, beside one registry key:

| File | What it holds |
|---|---|
| `native.json` | Settings: theme, font and size, notification choices, window position and size, the default launch profile, whether each WSL distribution's agterm-server starts at launch, and the local sessions open at quit. Each session keeps its name, the command line it started with and the folder it was last in, so it can start there again. |
| `config\keymap.conf` | Your key bindings, written only when you choose Edit Keymap. |
| `windows\wsl-<distribution>.json` | How agterm-win last showed an agterm-server's sessions, so the sidebar fills at once on the next start. |
| `agterm-win.log` | A diagnostic log: start and stop, sessions opened and closed, the commands that started them, the title and text of notifications posted to a session, errors. It does not record what you type or what programs print. |
| `crash.log` | Written only when agterm-win crashes: the error and where it happened. |
| `HKCU\Software\Classes\AppUserModelId\andriyg76.agterm-win` (registry, installs outside the Store) | The name and icon Windows shows on agterm-win's notifications. |
| `agterm.sock` | The local control socket `agtermctl` talks to. It sits in your profile's local app data, which Windows opens only to your account and administrators, and it carries nothing off the machine. |

Terminal contents and scrollback stay in memory: they are not written to disk and are gone when a session
closes.

Sessions served by agterm-server keep their state inside your WSL distribution, under the Linux account's
`~/.local/state/agterm`, where they keep running after agterm-win closes.

Local sessions started with `--local` are held by `zmx` processes on this computer until you close them or sign
out.

## Removing your data

Close agterm-win and delete `%LOCALAPPDATA%\agterm-win`, and on an install outside the Store the
`HKCU\Software\Classes\AppUserModelId\andriyg76.agterm-win` registry key. Uninstalling, including from the Store, may leave that
folder in place, so delete it yourself if you want nothing left behind. agterm-server's data in WSL is removed
with `~/.local/state/agterm` there, or with the distribution.

## Children

agterm-win is a developer tool. It is not directed at children and collects no data from anyone.

## Changes

Changes to this policy are made in this file, so its history is the record of every version.

## Contact

Questions about this policy: open an issue at https://github.com/andriyg76/agterm-win/issues.
