# Microsoft Store submission (agterm-win)

Product **9N0DD68BCXZX** · Publisher **Andriy Gushuley** · Manifest `packaging/msix/AppxManifest.xml`.

## Policy path (Store-compliant)

- **Policy:** 10.6.3 Capabilities  
- **Change:** removed `unvirtualizedResources`; production manifest uses **default** MSIX file/registry virtualization (no `desktop6:*Virtualization` disabled).  
- **Restricted capability in submission:** `runFullTrust` only (text in `store-listing.md`).  
- **Legacy:** `AppxManifest.unvirtualized.xml` and `msix.ps1 -Unvirtualized` are for local/winget parity tests, **not** uploaded to Partner Center.

Resubmit **both** architecture MSIX from `windows-release` without changing identity. Manual smoke: `TESTING-VIRTUALIZED.md`.

## Partner Center fields (copy from `store-listing.md`)

| Field | Value |
|-------|--------|
| Privacy policy | https://github.com/andriyg76/agterm-win/blob/windows-port/agterm-windows/PRIVACY.md |
| Website / developer URL | https://github.com/andriyg76/agterm-win |
| Support | Use a **reachable email** in Partner Center |
| Category | Developer tools |
| Min OS | Windows 10 1903 (18362) |

## Ukrainian checklist (Partner Center)

1. Новий submission з MSIX x64 + arm64 з **поточного** `AppxManifest.xml` (без `unvirtualizedResources`).  
2. Restricted capabilities: лише `runFullTrust` — текст з `store-listing.md`.  
3. Support **email** у формі.  
4. На другому ПК: WSL + `agtermctl` з `TESTING-VIRTUALIZED.md`.  
5. Очікування: Store MSIX state **не** в `%LOCALAPPDATA%\agterm-win`; winget/Inno лишають старий шлях — документувати в release notes при першому Store-оновленні.

## Previous reconsideration (archived 2026-11-25)

Earlier denial of `unvirtualizedResources` led to reconsideration text in git history; the product now complies by removing that capability instead of appealing again.