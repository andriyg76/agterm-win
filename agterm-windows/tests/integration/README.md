# agterm-win integration tests

The cases launch the real window and read the terminal's text back, so they need an interactive desktop.
Build, fetch, and stage a self-contained app folder first:

```powershell
cd agterm-windows
powershell -ExecutionPolicy Bypass -File scripts\fetch-webview2.ps1
powershell -ExecutionPolicy Bypass -File scripts\fetch-xterm.ps1
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

Sandbox needs the `Containers-DisposableClientVM` feature, a restart, and one manual start from Start to finish
installing its client. Each case leaves `screen.txt`, its state directory (`agterm-win.log`, `crash.log`) and
`cases.json` under the results folder.
WSL and remote cases run only on the desktop: Sandbox has no WSL.
