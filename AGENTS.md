# agterm-win upstream parity

Before implementing or changing an agterm-win option, command, or user-facing feature, check the corresponding behavior in [upstream agterm](https://github.com/umputun/agterm) (`upstream`). This applies to Windows behavior implemented in shared code as well as in `agterm-windows/`.

- Identify the upstream implementation, tests, or documentation and record the upstream revision or permalink. Check the relevant entry points, defaults, and observable behavior, including error cases where applicable.
- Verify that the Windows implementation matches that behavior. Record any Windows-specific differences and why they are needed. If upstream has no equivalent, record that finding and state the intended Windows behavior.
- Include the upstream reference and parity result in the PR’s `Summary`. Request changes when the comparison is missing or a behavioral difference is unexplained. Resolve those findings before merging.

# Shared host adapters in agtermCore

Host-free rules a terminal host applies to the model live in `agtermCore`, never as a Windows-only copy in `agterm-windows/`.
This covers what a pane reports (title, cwd, notifications, keystrokes that clear status) and how naming, notification and clipboard policy, background overlays, the session switcher, palette rows and pick status are decided.
macOS (upstream) and Linux ([agterm-linux](https://github.com/melonamin/agterm-linux)) call the same seams.

- New Windows code calls the core adapter when one exists. The Windows side only converts platform input (a ConPTY title, a Win32 key, a Windows path) and applies side effects (repaint, focus, taskbar).
- A fix or rewrite of Windows code that carries its own copy of such a rule switches to the core adapter and deletes the copy in the same change.
  If no adapter exists, add one to `agtermCore` with `agtermCore` tests instead of a Windows-only helper, starting from agterm-linux's implementation when it has one.
- Local and server sessions go through the same adapter. A change that wires only one of the two paths is incomplete.
- An adapter upstream does not ship yet is a fork delta: keep it under `agtermCore/Sources/agtermCore/HostAdapters/`, one concern per file, so an upstream PR can move it together with the macOS adoption.
- Name the adapter used, or the one added, in the PR's `Summary`.

# Manual Windows gate

Hosted CI skips the WSL and Docker cases; `windows-gate.yml` runs them by hand on a self-hosted box (`docs/windows-gate-runner.md`).

- A PR touching WSL, the agterm-server install or start (`WSLServerEnsure`, `RemoteHost`, `NativeShell`'s server path),
  `remote.properties` remotes, Docker remotes, server panes, server overlays or presentation, or `tests/integration/{wsl,docker-remote,overlay}*`
  gets a comment asking for a windows-gate run: the build to test (that PR's `windows.yml` run id), the `cases` wildcards, and
  whether `server-gate` is needed. An issue fixed by such a change gets the same request before it is closed.
- Ask once per PR, and again only after a later push changes those paths. Name the gate run's result in the PR when it is in.
- The gate result does not replace hosted CI; a red `windows.yml` is fixed first, since its portable build is what the gate tests.
