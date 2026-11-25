# MSIX Store-virtualized test package

Use this to try agterm as Microsoft would ship it **without** the `unvirtualizedResources` capability: default
file and registry write virtualization, same as omitting `desktop6:*Virtualization` disabled in the production manifest.

Production manifest: `AppxManifest.xml`. Test manifest: `AppxManifest.store-virtualized.xml` (selected with
`scripts/msix.ps1 -Virtualized`).

## Build

After `scripts/stage.ps1`:

```powershell
.\scripts\msix.ps1 -Version 0.44.1.999 -Arch x64 -Stage build\release\stage -Output build\release -Virtualized -LayoutOnly
# optional: pack unsigned .msix
.\scripts\msix.ps1 -Version 0.44.1.999 -Arch x64 -Stage build\release\stage -Output build\release -Virtualized
```

On a PR or push for `feature/msix-virtualized-test`, CI uploads `msix-virtualized-layout-<arch>` artifacts (the layout folder).
The workflow gates on `github.head_ref` / `github.ref_name`, not `github.ref` (PR merges use `refs/pull/.../merge`).

## Install (Developer Mode)

Settings → Privacy & security → For developers → **Developer Mode** on.

Remove any prior test package:

```powershell
Get-AppxPackage *agterm* | Remove-AppxPackage
```

Register the layout (unsigned):

```powershell
Add-AppxPackage -Register build\release\msix-virtualized\AppxManifest.xml
```

Start **agterm (virtualized test)** from the Start menu. Use `agtermctl tree` from a new console.

## What to check

1. Where state lives: `%LOCALAPPDATA%\agterm-win` vs `%LOCALAPPDATA%\Packages\*\LocalCache` / `LocalState`.
2. WSL: list distributions, start server, catalog sessions, reconnect after app restart.
3. Local PowerShell/cmd session; write a file under `$env:USERPROFILE` and see it from another terminal.
4. Compare with the same build run unpackaged: `build\release\stage\agterm-win.exe`.

Unregister when done:

```powershell
Get-AppxPackage *agterm* | Remove-AppxPackage
```

## CI

GitHub Actions builds the virtualized layout on branch `feature/msix-virtualized-test` and attaches it as an artifact.
Runners do **not** register the MSIX (no Developer Mode / interactive Store install in CI). Behavioral testing is on a
physical machine or VM with Developer Mode.