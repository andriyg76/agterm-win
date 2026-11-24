---
paths:
  - "agterm-windows/**"
  - ".github/workflows/windows.yml"
---

## Integration tests are part of every Windows feature

- A user-visible feature or control command in agterm-win is not done until `agterm-windows/tests/integration` has a
  case that drives the real window the way a user, Windows or `agtermctl` does, and reads the outcome back.
  `AgtermWinKitTests` alone never covers it; write both in the same change.
- This includes an upstream command agterm-win starts serving after a sync: `session.paste.text` has `session-paste`.
- A refusal a script can hit (a missing pane, an unknown id) gets a check in that case too.
- Put the case in the file for what it drives: `shell-cases.ps1` (`agtermctl`), `settings-cases.ps1`,
  `title-bar-cases.ps1`, `palette-cases.ps1`, `wsl-cases.ps1`; `run.ps1` picks up every entry.
  Use `Invoke-Ctl`, and `Invoke-CtlInput` for a command that reads stdin.
- A Linux session has no Windows desktop, PowerShell or Swift for Windows. Say so, and treat the `windows`
  workflow on the PR as the first run; never call a case verified before it is green there.
