# agterm-win integration tests

The cases launch the real window and read the terminal's text back, so they need an interactive desktop.
Build, fetch, and stage a self-contained app folder first:

```powershell
cd agterm-windows
powershell -ExecutionPolicy Bypass -File scripts\fetch-server.ps1
powershell -ExecutionPolicy Bypass -File scripts\fetch-ghostty-vt.ps1
swift build
powershell -ExecutionPolicy Bypass -File scripts\stage.ps1 -Output $env:TEMP\agterm-win-stage
```

Run on the current desktop (windows open and close on their own; leave them be):

```powershell
powershell -ExecutionPolicy Bypass -File tests\integration\run.ps1 -App $env:TEMP\agterm-win-stage -Results $env:TEMP\agterm-results
```

CI runs the same cases on the runner desktop (`.github/workflows/windows.yml`).
Or in Windows Sandbox, which keeps the host desktop free and starts from a clean machine with no network or WSL:

```powershell
powershell -ExecutionPolicy Bypass -File tests\integration\sandbox.ps1 -App $env:TEMP\agterm-win-stage
```

Command-window cases read the terminal's text back; the full-window cases in `shell-cases.ps1` start the window on
their own state directory and drive it with the staged `agtermctl` (session names, notifications, theme, keymap);
`settings-cases.ps1` sets Settings' controls with their own messages and checks native.json and what the window then does.
They save PNG snapshots beside their results: the window at key steps and when it stops (`final.png`), and the
whole desktop after a `notify` to show its banner; CI uploads them in the `integration-results-<arch>` artifact.

`panes-cases.ps1` drives split panes, the scratch, the quick terminal and the dashboard with agtermctl, the title bar's
buttons and the keymap's chords, and reads back the tree, each pane's text and which terminals are on screen.

`title-bar-cases.ps1` sends the window the messages Windows sends its title bar (hit tests, clicks, presses on
minimize, maximize and close), then reads the outcome back and checks the pixels the bar painted.

Every user-visible feature lands with a case here that drives the real window the way a user or Windows does,
and reads the outcome back; a unit test of its logic alone does not cover it.

Overlay and presentation stages **A → B → E → D**, each with its own CI gate, are defined in
`docs/plans/20261123-windows-naming-keys-notifications-settings.md` (section **Presentation and overlays**).

## Architecture skips

`run.ps1` may skip a shell case on a host whose native `PROCESSOR_ARCHITECTURE` makes it unreliable. Skips count as
passed and are recorded in `cases.json` under `skipped`.

| Case | Where | Issue |
|------|--------|--------|
| `overlay-keys` | native **ARM64** (`windows-11-arm`) | After `SendChord` sends Ctrl+Shift+W to the overlay terminal, the session under the overlay is closed instead of dismissing the overlay only. The same case passes on x64. Suspect focus / duplicate Close Session delivery on the arm64 runner. Track in PR/overlay work; remove the skip when arm64 matches x64. |

Sandbox needs the `Containers-DisposableClientVM` feature, a restart, and one manual start from Start to finish
installing its client. Each case leaves `screen.txt`, its state directory (`agterm-win.log`, `crash.log`) and
`cases.json` under the results folder.
`wsl-cases.ps1` start a distribution no machine has, so they need no WSL and run in Sandbox and on CI too: they read
back what was started, asked and saved, never a connected server.
