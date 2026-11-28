# Windows gate runner

`.github/workflows/windows-gate.yml` runs the WSL and Docker integration cases that `windows.yml` skips:
GitHub's Windows VMs are already nested, so they offer neither WSL2 nor Linux containers.
It is started by hand and tests a build that already exists; it builds nothing.
The job runs on one self-hosted box labelled `agterm-gate`, with `AGTERM_WIN_GATE_WSL=1`, and fails when any case skips.

## Running it

Actions ▸ windows-gate ▸ Run workflow, or `gh workflow run windows-gate.yml -f build=<build>`:

- `build`: a release tag (`v0.44.1.11`), whose `*-x64-portable.zip` asset is tested, or a `windows.yml` run id or URL,
  whose `ci-portable-x64` artifact is tested. A PR's own `windows.yml` run tests that PR.
- `cases`: `run.ps1 -Case` wildcards, comma-separated, `*` by default; for example `wsl-*,docker-remote`.
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
- WSL2 with an `Ubuntu` distribution whose `/etc/wsl.conf` has `[boot] systemd=true`, and agterm-server installed in it
  (`agtermctl server install Ubuntu` from a staged build, or `--install-server` once).
- Docker Desktop on the WSL2 backend in Linux containers mode, started at sign-in.

## Runner

1. In the repository: Settings ▸ Actions ▸ Runners ▸ New self-hosted runner, Windows x64.
   Configure with `--labels agterm-gate` and answer **no** to running as a service: a service runs in session 0,
   which has no desktop and no WSL for the user.
2. Turn on automatic sign-in for the runner's account (Sysinternals Autologon), so a reboot comes back to session 1.
3. Put a shortcut to the runner's `run.cmd` in `shell:startup`.
4. Turn off screen lock and sleep for that account; a locked desktop takes input away from the cases.

## What the job checks

The first step fails fast when the runner is in session 0, when `wsl -l -q` lists no `Ubuntu`,
when Docker does not answer with Linux containers,
and when `gh` is missing.
Then it runs `tests/integration/run.ps1` with the chosen cases and `tests/integration/wsl-server-gate.ps1`.
Results of both are uploaded as `gate-results`.

## When a run is needed

A PR or issue whose change reaches WSL, the agterm-server install or start, `remote.properties` remotes, Docker remotes,
or server overlays and presentation needs a windows-gate run before merge or close; `AGENTS.md` says who asks for it.
