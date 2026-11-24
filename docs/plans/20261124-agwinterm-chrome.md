# agwinterm chrome import (palette, sidebar, menu bar, settings skin)

**Checkout:** `agterm-win-agtermctl-output` (not `agterm-win/page-overlays`). Branch: `feature/agwinterm-chrome` (base `feature/presentation-ui`). WIP lives here uncommitted until the PR is ready.

Single PR on `feature/agwinterm-chrome` against `windows-port`.

## Remaining (2026-11-24)

Land on `windows-port`: local build + integration on Windows, then PR against `feature/presentation-ui` / `windows-port`.

## 1 — Chrome palette

- `ChromePalette.recompute` from active `TerminalTheme` (+ `sidebarTint`), porting agwinterm `RecomputeChrome`.
- `nt_set_chrome_colors` + `NativeChrome.cpp`; title bar, tree, palette read dynamic colors.
- `applyChrome()` on launch, theme change, and `WM_SETTINGCHANGE` (ImmersiveColorSet).

**Tests:** `ChromePaletteTests`.

## 2 — Sidebar width

- Persist `sidebarWidthPoints` / `sidebarTint` in `NativeSettings`.
- Divider drag; `sidebar.width` via `NativeControl`.

**Tests:** `SidebarWidthTests`, updated `TitleBarTests`.

## 3 — Menu bar in title bar

- `MenuBarLayout` (File / View / Navigate / Help); drop hamburger.
- `nt_title_bar_paint` menu tab labels; hit-test + `nt_track_menu`.

**Tests:** `MenuBarLayoutTests`, `TitleBarTests`.

## 4 — Settings / dialogs chrome

- Settings HWND: `WM_CTLCOLOR*` + `SetWindowTheme` from palette; Task Dialog inherits active chrome.

**Tests:** extend `NativeSettingsTests` round-trip for new keys.

## CI

`windows.yml` runs `swift test` then integration; branch `feature/agwinterm-chrome` included in `push.branches`.