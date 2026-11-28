# Windows troubleshooting

Where agterm-win keeps its files, the common problems, and what to include in a bug report.
[troubleshooting.md](troubleshooting.md) covers the upstream macOS app.

## Where things live

Every install type, the Microsoft Store app included, uses the same two folders:

- **State**, `%USERPROFILE%\.local\state\agterm-win`: the log (`agterm-win.log`; a notice bar with an error offers
  **Open Log**), `crash.log`, settings (`native.json`), the control socket `agterm-<hash>.sock`, where the hash comes
  from the state folder's path, and Live sessions' zmx sockets and logs in `z\<id>`.
- **Config**, `%USERPROFILE%\.config\agterm`, upstream agterm's config folder:
  - **Keymap**: `keymap.conf`. **File ▸ Settings ▸ Edit Keymap…** opens it.
  - **Launch profiles**: `profiles.properties`. **File ▸ Settings ▸ Edit Launch Profiles…** opens it, and Reload Keymap applies it.
  - **WSL and remote hosts**: `remote.properties`.
  - **Themes**: `themes`.
  - **Agent status scripts**: `agent-status`.

`AGTERM_WIN_STATE_DIR` moves the state folder, for example to run an isolated second instance, and that instance keeps
its config in the state folder's `config`.

agterm-win 0.44.1.11 and earlier kept everything in `%LOCALAPPDATA%\agterm-win` (the Store app in
`%LOCALAPPDATA%\Packages\AndriyGushuley.agterm_<id>\LocalCache\Local\agterm-win`). The first start of a later version
moves state there into the new state folder while that holds no `native.json` or `windows` folder, and config while the
config folder holds none of the old files; otherwise it leaves the old folder alone. Live sessions an older version
started end at that start, and their `zmx` folder is removed.

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
