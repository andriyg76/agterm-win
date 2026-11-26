# Menu and main-window follow-ups

The existing menu/main-window changes are the baseline. These follow-ups keep the agreed session and workspace creation behavior.

Upstream comparison: [agterm 3871300](https://github.com/umputun/agterm/tree/3871300eef59fae72701f451ac2738fa4c3351a2).
`agterm/Views/WindowContentView+Titlebar.swift` exposes Toggle Sidebar in the title bar. Windows now exposes it there,
in View and through the shared keymap action, preserving the configured width when hidden. Old settings default to visible.
macOS uses the system application menu; Windows deliberately keeps its menu labels in the combined caption row.
The sidebar footer buttons use native mouse tracking for hover, with disabled and checked states preserved.

Upstream `agterm/agtermApp+Menus.swift` uses the standard About panel and an optional GitCommit value.
Windows deliberately shows the four-component Windows package version, the executable build date in UTC and,
for GitHub Actions builds, the head branch and PR number when present. `stage.ps1` writes `build-info.json` alongside
the executable; release and CI packaging pass the same version used by their installer/MSIX. Source builds fall back
to upstream-version `.0` and the executable modification date, without inventing CI details.
