# Windows gate

The WSL and Docker integration cases need WSL2 and Linux containers, which GitHub's Windows VMs cannot run: they are
already nested. Hosted `windows.yml` skips them. `agterm-windows/tests/integration/gate.ps1` runs them by hand on a
Windows box against a build that already exists; it builds nothing and is no CI job.

## Running it

From a checkout of this repository on the box, in PowerShell 7:

```powershell
.\agterm-windows\tests\integration\gate.ps1 -Build 46158804275        # a windows.yml run's ci-portable-x64 (id or URL)
.\agterm-windows\tests\integration\gate.ps1 -Build v0.44.1.11         # a release's *-x64-portable.zip
.\agterm-windows\tests\integration\gate.ps1 -App $env:TEMP\stage      # a local stage.ps1 output, this checkout's cases
```

- `-Case` takes `run.ps1` wildcards, all cases by default, for example `-Case wsl-*,docker-remote,server-panes`.
- `-NoServerGate` leaves out `wsl-server-gate.ps1`.
- The cases come from the build's own commit, unpacked beside the build, so they match it and the checkout is left as it is.
- The gate fails when any case fails or skips, since `run.ps1` counts a skip as a pass.
- `gate-summary.md` under `-Results` (default `%TEMP%\agterm-gate-results`) is the result as the PR records it.

## Its own distribution

The gate never uses a distribution someone works in. Each run imports a fresh one named `agterm-gate-<timestamp>`
from Ubuntu's WSL rootfs (`gate-wsl.ps1`), boots systemd with a lingering `agterm` user, installs agterm-server with
the tested build's `agtermctl`, and passes the name to the cases as `AGTERM_WIN_GATE_WSL`.
It is unregistered when the run ends, and any `agterm-gate-*` a killed run left behind is removed at the start of the
next. The script refuses every other name. The rootfs is cached under `%LOCALAPPDATA%\agterm-gate` and downloaded again
only when Ubuntu's `SHA256SUMS` changes.
A build whose cases predate this is refused, since its `wsl-at-launch-unseeded` starts a server in the first listed
distribution.

## Box

- Windows 11 x64 with virtualization on; a VM needs nested virtualization.
- PowerShell 7, Git for Windows and the GitHub CLI (`gh`), signed in, to download a build.
- WSL2; no distribution needs to be set up, and the box's own ones are left alone.
  Network access to `cloud-images.ubuntu.com` and to the agterm-server release download.
- Docker Desktop on the WSL2 backend in Linux containers mode.
- An unlocked interactive desktop while it runs: the cases open real windows and send keys to them.

## When a run is needed

A PR or issue whose change reaches WSL, the agterm-server install or start, `remote.properties` remotes, Docker remotes,
server panes, or server overlays and presentation needs a gate run before merge or close; `AGENTS.md` says how its result
is recorded.
