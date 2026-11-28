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

Hosted CI skips the WSL and Docker cases. The agent working on a change runs them itself on the Windows box with
`agterm-windows/tests/integration/gate.ps1` (`docs/windows-gate.md`); there is no runner and no workflow for it.

- A PR touching WSL, the agterm-server install or start (`WSLServerEnsure`, `RemoteHost`, `NativeShell`'s server path),
  `remote.properties` remotes, Docker remotes, server panes, server overlays or presentation, or
  `tests/integration/{wsl,docker-remote,overlay,gate}*` needs a gate run on that PR's green `windows.yml` build.
  An issue fixed by such a change needs one before it is closed.
- Run it on the box, then post `gate-summary.md` on the PR and tick its test-plan line. A failure is fixed like red CI.
  When the box is not attached to the session, say so on the PR once and ask the user to attach it.
- Run again after a later push changes those paths. The gate does not replace hosted CI: a red `windows.yml` is fixed first.
