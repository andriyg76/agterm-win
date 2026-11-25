# Microsoft Store submission (agterm-win)

Product **9N0DD68BCXZX** · Publisher **Andriy Gushuley** · Manifest `packaging/msix/AppxManifest.xml`.

## Review outcome (2026-11-25)

- **Policy:** 10.6.3 Capabilities  
- **Result:** `unvirtualizedResources` **denied**  
- **Store guidance:** Remove the capability and resubmit, **or** request reconsideration with **new or expanded** business justification plus a **valid support contact or developer website URL**.

**Do not** remove `unvirtualizedResources` while leaving `desktop6:FileSystemWriteVirtualization` and
`RegistryWriteVirtualization` set to **disabled** — that pair requires the capability for a working terminal
(WSL, `agterm-server`, `agterm.sock`, real `%LOCALAPPDATA%\agterm-win`). See `TESTING-VIRTUALIZED.md` for a
side-by-side MSIX test **without** the capability (default virtualization only).

Production packages from `windows-release` and Partner Center submissions must keep `AppxManifest.xml` as on
`windows-port`. The virtualized manifest is **test-only**.

## Partner Center fields (copy from `store-listing.md`)

| Field | Value |
|-------|--------|
| Privacy policy | https://github.com/andriyg76/agterm-win/blob/windows-port/agterm-windows/PRIVACY.md |
| Website / developer URL | https://github.com/andriyg76/agterm-win |
| Support | Use a **reachable email** in Partner Center (issues-only URLs are often rejected on reconsideration) |
| Category | Developer tools |
| Min OS | Windows 10 1903 (18362) |

## Reconsideration — paste under `unvirtualizedResources` (English)

Use **Submission ▸ Properties ▸ Restricted capabilities**. Merge with the longer text in `store-listing.md` if the form allows more characters.

```
agterm is a full-trust desktop terminal for developers (PowerShell, cmd, WSL, coding agents). The package sets desktop6:FileSystemWriteVirtualization and RegistryWriteVirtualization to disabled and declares unvirtualizedResources so user programs and agterm itself use the same %LOCALAPPDATA%, %APPDATA% and HKCU paths as in Windows Terminal or an unpackaged install.

Without this capability, MSIX would redirect agterm's state (agterm.sock for agtermctl, session settings, WSL catalog cache) into a package-private folder, breaking scripts and a second install path (winget/Inno). User tools started in the terminal (git, npm, ssh) must see one consistent profile store; virtualization would fork config away from other terminals.

WSL: agterm runs wsl.exe, probes and optionally installs agterm-server inside the user's distribution, and keeps long-lived Linux sessions in a sidebar. That path depends on a stable Windows-side state directory and full trust; no elevation, no telemetry, no data collection.

Support: <your email>
Website: https://github.com/andriyg76/agterm-win
Privacy: https://github.com/andriyg76/agterm-win/blob/windows-port/agterm-windows/PRIVACY.md
```

Replace `<your email>` before submitting.

## Ukrainian checklist (що зробити в Partner Center)

1. Новий submission з тими ж MSIX (x64 + arm64), **без** зміни production manifest.  
2. Restricted capabilities: `runFullTrust` — текст з `store-listing.md`; `unvirtualizedResources` — текст вище + WSL абзац.  
3. Додати **email** у support (не лише GitHub issues).  
4. Якщо знову відхилять — оцінити reconsideration vs розповсюдження лише winget/Inno; паралельно прогнати `-Virtualized` пакет з `TESTING-VIRTUALIZED.md` на другому ПК.