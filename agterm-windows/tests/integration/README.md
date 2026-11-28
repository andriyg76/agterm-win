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

Overlay cases live in `overlay-cases.ps1` (local program/html, WSL catalog program/html). Run them with
`-Case overlay*` (legacy names `overlay` and `overlay-html` still match). `-StepSeconds 2` pauses after every step that changes
the window, to watch a case run. (`run.ps1` keeps the filter in `$casePatterns`; do not name a loop variable `$case`
while `-Case` is set — PowerShell treats `$Case` and `$case` as the same variable.)

CI runs the same cases on the runner desktop (`.github/workflows/windows.yml`).

`-Case sidebar-resize` reproduces #62 with real mouse input through Windows hit testing. It grabs the divider
from the sidebar and terminal sides, enlarges and shrinks it, checks the minimum clamp and the actual child-window
positions, then verifies the saved width after an app restart. The case runs in the normal x64 and arm64 CI matrix,
without WSL or an architecture skip. Screenshots are saved before the drag, after each release, and after restart.
The expected drag behavior follows upstream agterm's `sidebarDivider` at `3dc9f06a7ffd6cfbdbfec3ecea3cecfede39186e`:
a wider grab handle, absolute pointer position, shared width limits, and persistence on release.

Or in Windows Sandbox, which keeps the host desktop free and starts from a clean machine with no network or WSL:

```powershell
powershell -ExecutionPolicy Bypass -File tests\integration\sandbox.ps1 -App $env:TEMP\agterm-win-stage
```

Command-window cases read the terminal's text back; the full-window cases in `shell-cases.ps1` start the window on
their own state directory and drive it with the staged `agtermctl` (session names, notifications, theme, keymap);
`settings-cases.ps1` sets Settings' controls with their own messages and checks native.json and what the window then does.
They save PNG snapshots beside their results: the window after every agtermctl command that changes it
(`NN-<command>.png`, numbered in order), at the case's own key steps and when it stops (`final.png`), and the
whole desktop after a `notify` to show its banner; CI uploads them in the `integration-results-<arch>` artifact.

`panes-cases.ps1` drives split panes, the scratch, the quick terminal and the dashboard with agtermctl, the title bar's
buttons and the keymap's chords, and reads back the tree, each pane's text and which terminals are on screen.

`agent-status-cases.ps1` sets agent status, context and info and reads them back through the tree and the title bar,
then runs the staged Claude Code and Codex adapters with a hook's JSON on stdin, as the agents run them.

`message-cases.ps1` sends `agtermctl msg` from inside one pane to another, reads the pending count, the `message` event
and the receiver's own `msg read --ack`; `server-panes` repeats it between a server row's panes.

`pick-ask-cases.ps1` opens picks and asks with `agtermctl --no-block`, answers them with keys posted to the palette
field and the ask panel (arrows, Enter, Esc, hotkeys, a typed query or field), and reads each outcome back through
`pick result` and `ask result`, the tree's `pickPending`/`askPending` and the session node's `ask`.

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
| `overlay-keys` | native **ARM64** (`windows-11-arm`) | After `SendChord` sends Ctrl+W to the overlay terminal, the session under the overlay is closed instead of dismissing the overlay only. The same case passes on x64. Suspect focus / duplicate Close Session delivery on the arm64 runner. Track in PR/overlay work; remove the skip when arm64 matches x64. |
| `overlay-server-program`, `overlay-server-html`, `presentation-surfaces` | CI without `AGTERM_WIN_GATE_WSL` | **SKIP** (smoke runs in `overlay-server-disconnected`). Set `AGTERM_WIN_GATE_WSL` for full WSL catalog gates (`docs/remote-linux-gate.md`). |

| Case | Scope | CI |
|------|--------|-----|
| `overlay-local-refusals` | local ctl errors | always |
| `overlay-local-program` | local program overlay lifecycle | always (`overlay` alias) |
| `overlay-local-html` | local WebView2 `--html` | always (`overlay-html` alias) |
| `overlay-keys` | local keyboard / Close Session | x64 (arm64 skip) |
| `overlay-server-disconnected` | WSL smoke, overlay on unknown id | always |
| `overlay-server-program` | WSL catalog program overlay | skip unless `AGTERM_WIN_GATE_WSL` |
| `overlay-server-html` | WSL catalog `--html` | skip unless `AGTERM_WIN_GATE_WSL` |
| `server-panes` | agterm-server split, scratch, ratio and focus, on the `docker-remote` container | skip without Docker running Linux containers |

Sandbox needs the `Containers-DisposableClientVM` feature, a restart, and one manual start from Start to finish
installing its client. Each case leaves `screen.txt`, its state directory (`agterm-win.log`, `crash.log`) and
`cases.json` under the results folder.
`wsl-cases.ps1` start a distribution no machine has, so they need no WSL and run in Sandbox and on CI too: they read
back what was started, asked and saved, and how WSL auto-ensure probes and reports failures. Cases `wsl-ensure-probe`,
`wsl-ensure-reprobe`, and `wsl-install-unreachable` pin that behaviour; only a live install connects. Each seeds
`config\remote.properties` with `agterm-test-absent = wsl.exe -d agterm-test-absent -e`, except `wsl-not-at-launch`
and `wsl-at-launch-unseeded`, which check the file agterm writes from `wsl -l -q`, the second before a start at launch
resolves its name (the first listed distribution, `agterm-test-absent` with none). They read a remote through `window list` as its remote window,
open it with `window remote open`, try `session new --remote`, and change its start at launch in Settings ▸ General;
`wsl-install-unreachable` also runs `agtermctl server install` and expects the reason the notice showed. `notice-bar` uses
that failure to drag the notice bar to the bottom and back, check the terminal reflows and the bar follows the theme,
press Retry, and close it, reading the bar's text, position and pixels.

`docker-remote-cases.ps1` builds `docker-remote\Dockerfile` (Ubuntu LTS, systemd as pid 1, a lingering user, since
agterm-server runs only as a systemd user unit), starts it under a unique name with no published port, and defines it in
`remote.properties` as `agterm-docker`, reached by `docker exec` through `docker-tty.exe`, which the case compiles from
`DockerTty.cs` and which adds `-t` only when stdin is a console. With the window minimized it runs `agtermctl server
install`, opens the remote window, makes a session and reads its prompt, types a command and reads it back with the
pane's pty and size, closes the session and checks its daemons ended, stops the container and checks the remote
disconnects, then starts it and checks it reconnects and makes a session again. It records, rather than asserts, that the
container's loopback is not reachable from Windows: a defined remote gets no `-L` forward. The container and image are
removed whether the case passed or not. It needs Docker running Linux containers and skips without them, as on CI; run
it alone with `-Case docker-remote`.

On a machine with a working agterm-server in WSL, run the optional gate; `gate.ps1` runs it with every WSL and Docker
case, on a distribution of its own, with `AGTERM_WIN_GATE_WSL` naming it (`docs/windows-gate.md`).
`gate-wsl.ps1 -New agterm-gate-local -App <stage>` makes such a distribution by hand, and `-Remove agterm-gate-local` removes it:

```powershell
powershell -ExecutionPolicy Bypass -File tests\integration\wsl-server-gate.ps1 -App $env:TEMP\agterm-win-stage -Results $env:TEMP\wsl-gate -Distribution <name>
```
