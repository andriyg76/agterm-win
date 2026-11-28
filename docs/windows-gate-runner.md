# Windows gate runner

`.github/workflows/windows-gate.yml` runs the WSL and Docker integration cases that `windows.yml` skips:
GitHub's Windows VMs are already nested, so they offer neither WSL2 nor Linux containers.
The job runs on one self-hosted box labelled `agterm-gate`, with `AGTERM_WIN_GATE_WSL=1`, and fails when any case skips.

## Why a dedicated box

- The cases open real windows on the desktop and send keys to them; a machine someone works on gets in their way.
- The job runs whatever the pushed tree holds. The workflow never runs a fork's PR, but every branch pusher's code
  still runs as the box's user, so keep nothing on it you would not hand to a collaborator.

## Box

- Windows 11 x64 with virtualization on; a VM needs nested virtualization (Hyper-V `ExposeVirtualizationExtensions`).
- PowerShell 7 (`pwsh`) and Git for Windows.
- Visual Studio 2022 Build Tools with the C++ workload and a Windows SDK: MSVC 14.4x, as `windows.yml` explains.
  The workflow installs Swift itself.
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
5. Set the repository variable `AGTERM_WIN_GATE_RUNNER` to `true` (Settings ▸ Secrets and variables ▸ Actions ▸ Variables).
   Without it the job is skipped rather than queued for a runner that does not exist.

## What the job checks

The first step fails fast when the runner is in session 0, when `wsl -l -q` lists no `Ubuntu`,
or when Docker does not answer with Linux containers.
Then it runs unit tests, `tests/integration/run.ps1` with every case, and `tests/integration/wsl-server-gate.ps1`.
Results of both are uploaded as `gate-results`.
