# Windows gate runner

`.github/workflows/windows-gate.yml` runs the WSL and Docker integration cases that `windows.yml` skips:
GitHub's Windows VMs are already nested, so they offer neither WSL2 nor Linux containers.
It is started by hand and tests a build that already exists; it builds nothing.
The job runs on one self-hosted box labelled `agterm-gate` and fails when any case skips.

## Its own distribution

The gate never uses a distribution someone works in. Each run imports a fresh one named `agterm-gate-<run id>-<attempt>`
from Ubuntu's WSL rootfs (`tests/integration/gate-wsl.ps1`), boots systemd with a lingering `agterm` user, installs
agterm-server with the tested build's `agtermctl`, and passes the name to the cases as `AGTERM_WIN_GATE_WSL`.
The distribution is unregistered at the end of the run, and any `agterm-gate-*` a killed run left behind is removed at
the start of the next. The script refuses every other name. The rootfs is cached under `%LOCALAPPDATA%\agterm-gate`
and downloaded again only when Ubuntu's `SHA256SUMS` changes.
A build whose cases predate this is refused, since its `wsl-at-launch-unseeded` starts a server in the first listed
distribution.

## Running it

Actions ▸ windows-gate ▸ Run workflow, or `gh workflow run windows-gate.yml -f build=<build>`:

- `build`: a release tag (`v0.44.1.11`), whose `*-x64-portable.zip` asset is tested, or a `windows.yml` run id or URL,
  whose `ci-portable-x64` artifact is tested. A PR's own `windows.yml` run tests that PR.
- `cases`: `run.ps1 -Case` wildcards, comma-separated, `*` by default; for example `wsl-*,docker-remote,server-panes`.
- `server-gate`: also run `wsl-server-gate.ps1`, on by default.

The test scripts are checked out at the build's own commit, so they match the build. The run's summary names the build.
A run artifact from a fork's PR runs that fork's code on the box: start it only for code you have read.

## Why a dedicated box

- The cases open real windows on the desktop and send keys to them; a machine someone works on gets in their way.
- The job runs the build and scripts it was pointed at as the box's user; keep nothing on it you would not hand to a
  collaborator.

## Box

- Windows 11 x64 with virtualization on; a VM needs nested virtualization (Hyper-V `ExposeVirtualizationExtensions`).
- PowerShell 7 (`pwsh`), Git for Windows and the GitHub CLI (`gh`), which downloads the build.
- No toolchain: the build comes from a release or a `windows.yml` run, with its runtime DLLs.
- WSL2. No distribution needs to be set up, and the box's own ones are left alone; the job needs network access to
  `cloud-images.ubuntu.com` and to the agterm-server release download.
- Docker Desktop on the WSL2 backend in Linux containers mode, started at sign-in.

## Runner

1. In the repository: Settings ▸ Actions ▸ Runners ▸ New self-hosted runner, Windows x64.
   Configure with `--labels agterm-gate` and answer **no** to running as a service: a service runs in session 0,
   which has no desktop and no WSL for the user.
2. Turn on automatic sign-in for the runner's account (Sysinternals Autologon), so a reboot comes back to session 1.
3. Put a shortcut to the runner's `run.cmd` in `shell:startup`.
4. Turn off screen lock and sleep for that account; a locked desktop takes input away from the cases.

## What the job checks

The first step fails fast when the runner is in session 0, when `wsl --status` fails,
when Docker does not answer with Linux containers,
and when `gh` is missing.
Then it makes the run's distribution, runs `tests/integration/run.ps1` with the chosen cases and
`tests/integration/wsl-server-gate.ps1` against it, and removes it.
Results of both are uploaded as `gate-results`.

## When a run is needed

A PR or issue whose change reaches WSL, the agterm-server install or start, `remote.properties` remotes, Docker remotes,
server panes, or server overlays and presentation needs a windows-gate run before merge or close; `AGENTS.md` says who asks for it.
