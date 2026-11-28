# Windows troubleshooting

Where agterm-win keeps its files, the common problems, and what to include in a bug report.
[troubleshooting.md](troubleshooting.md) covers the upstream macOS app.

## Where things live

agterm-win keeps everything in its state folder, `%LOCALAPPDATA%\agterm-win`.
The Microsoft Store package writes to a redirected copy instead:
`%LOCALAPPDATA%\Packages\AndriyGushuley.agterm_<id>\LocalCache\Local\agterm-win`.
`AGTERM_WIN_STATE_DIR` moves the state folder, for example to run an isolated second instance.

- **Log**: `agterm-win.log`. A notice bar with an error offers **Open Log**.
- **Crash log**: `crash.log`.
- **Settings**: `native.json`.
- **Keymap**: `config\keymap.conf`. **File ▸ Settings ▸ Edit Keymap…** opens it.
- **Launch profiles**: `config\profiles.properties`. **File ▸ Settings ▸ Edit Launch Profiles…** opens it, and Reload Keymap applies it.
- **WSL and remote hosts**: `config\remote.properties`.
- **Themes**: `config\themes`.

Sockets live outside AppData, in `%USERPROFILE%\.local\state\agterm-win`, so the Store app and an `agtermctl` from any install meet on the same path.
The control socket there is `agterm-<hash>.sock`, where the hash comes from the state folder's path.

## agtermctl cannot connect

`agtermctl` finds the running app's control socket from `AGTERM_STATE_DIR`, or from the default state folder when it is unset.

- Start agterm-win first; the CLI does not launch it.
- Sessions get `AGTERM_STATE_DIR` from the app. In another terminal, a stale or different `AGTERM_STATE_DIR` points `agtermctl` at another instance's socket: unset it, or pass `--socket`.

## Checking the keymap

Changes to `keymap.conf` apply after a reload.

- **File ▸ Settings ▸ Reload Keymap**, or `agtermctl keymap reload`, re-reads the file. The command prints how many problems it found; `0` means a clean reload.
- `agtermctl keymap list` shows what is actually bound, with each problem in full.
- [windows-shortcuts.md](windows-shortcuts.md) lists the Windows defaults and how `cmd` maps to keys.

## Sessions ended after an update

A Microsoft Store update ends the package's processes, so local sessions close and do not reattach.
This is a Windows platform limit for packaged apps.
Sessions on a WSL server run inside the distribution and survive it: open them again from the sidebar.

## A WSL server does not start

A failed start shows a notice bar with the reason and **Retry**, **Install** or **Restart WSL**, plus **Open Log**.
The log records the probe, the install and the server's exit code.
The first install downloads agterm-server from upstream agterm's GitHub release, so it needs network access to GitHub.

## SmartScreen warns on first run

The GitHub installer and portable ZIP are not code-signed yet, so SmartScreen shows a warning the first time.
Choose **More info ▸ Run anyway**, or install from the Microsoft Store, which signs its package.

## Reporting a bug

Open an issue in the [agterm-win tracker](https://github.com/andriyg76/agterm-win/issues) with:

- the agterm-win version and how you installed it (Store, installer or portable ZIP);
- the Windows version and architecture (x64 or ARM64);
- steps to reproduce;
- the relevant lines of `agterm-win.log`, and `crash.log` after a crash.

Check the log for user names, host names and paths you do not want to publish before attaching it.
