# MSIX Store package (default virtualization)

Production manifest `AppxManifest.xml` follows Microsoft Store policy **without** `unvirtualizedResources`
(10.6.3): file and registry writes from **agterm and agtermctl** use the package's redirected profile.

Legacy manifest with `unvirtualizedResources` (winget-style `%LOCALAPPDATA%\agterm-win`): `AppxManifest.unvirtualized.xml`
via `scripts/msix.ps1 -Unvirtualized` (not for Store submission).

## Build

After `scripts/stage.ps1`:

```powershell
.\scripts\msix.ps1 -Version 0.44.1.999 -Arch x64 -Stage build\release\stage -Output build\release -LayoutOnly
.\scripts\msix.ps1 -Version 0.44.1.999 -Arch x64 -Stage build\release\stage -Output build\release
```

Every `windows` workflow run uploads `ci-installer-<arch>` (Inno setup), `ci-msix-<arch>` (`.msix`), and `msix-store-layout-<arch>` (registerable layout with sideload `.bat` files).

## Install (Developer Mode)

Settings → Privacy & security → For developers → **Developer Mode** on, or run
`packaging/msix/sideload/install-agterm-msix.bat` as administrator.

Remove any prior test package:

```powershell
Get-AppxPackage *agterm* | Remove-AppxPackage
```

Register the layout (unsigned):

```powershell
Add-AppxPackage -Register build\release\msix\AppxManifest.xml
```

Start **agterm** from the Start menu, or `start-agterm-msix.bat` from the layout folder (see `packaging/msix/sideload/`).

## What to check

1. Where agterm state lives: redirected `%LOCALAPPDATA%` under `Packages\<family>\…`, not `%LOCALAPPDATA%\agterm-win`.
2. WSL: list distributions, start server, catalog sessions, reconnect after app restart.
3. Local PowerShell/cmd session; user tools in the terminal still use the user's normal profile paths.
4. `agtermctl tree` from the MSIX execution alias (same package context as agterm).
5. Compare with unpackaged `build\release\stage\agterm-win.exe` or `-Unvirtualized` layout for migration notes.

Unregister when done:

```powershell
Get-AppxPackage *agterm* | Remove-AppxPackage
```

## CI

GitHub Actions builds packages on every `windows` CI run (unsigned; not SignPath-signed).
Runners do **not** register the MSIX. Behavioral testing is on a physical machine, VM, or Windows Sandbox with Developer Mode.