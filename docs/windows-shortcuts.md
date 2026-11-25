# Windows shortcut assignments

Agreed 2026-11-25 against agterm's macOS defaults. This is the target scheme and the implementation status of
this change, not a claim that every macOS feature already exists in agterm-win.

Use Command → Ctrl where the combination is free, with the shell exceptions and explicit assignments below.
In `keymap.conf`, `cmd` still means the Windows key; it does not mean Ctrl. No default uses the Windows key.

## Available actions

These defaults are applied by this change. Existing menu/control actions stay available when their shortcut is removed.

| Action | macOS default | Windows default | Behavior / scope |
|---|---|---|---|
| New Session | Command+N | Ctrl+N | In the selected session's workspace: Local, or that session's server workspace. With no selected session, use the local default profile. |
| Close Session | Command+W | Ctrl+W | Dismiss a visible overlay first; otherwise close the session. |
| Previous / next session | Command+Option+Up / Down | Ctrl+Alt+Left / Right | Sidebar order, wrapping; distinct from the future MRU switcher. |
| Find | Command+F | Ctrl+F | Search terminal output. |
| Increase font size | Command++ | Ctrl++ | The plus key is Ctrl+Shift+= (`ctrl+shift+=` in keymap.conf); Ctrl+= is not an alias. |
| Decrease / reset font size | Command+- / Command+0 | Ctrl+- / Ctrl+0 | Focused terminal. |
| Split side by side | Command+D | Ctrl+Shift+D | Show/hide a side-by-side split; Ctrl+D remains available to the shell. |
| Split top and bottom | Command+Shift+D | None | Menu/control action. |
| Focus primary / second pane | Command+Option+Left / Right; Ctrl+1 / 2 | Ctrl+1 / Ctrl+2 | Primary = left/top; second = right/bottom. |
| Scratch | Command+J | None | Menu/control action. |
| Overlay | Command+Shift+J | Ctrl+Shift+J | Show/hide an existing local or server session overlay. Does not create an overlay when none exists. Page content with keyboard focus may own its keys. |
| Quick Terminal | Ctrl+backtick | Ctrl+backtick | In-app toggle; a system-wide shortcut requires an explicit `global-hotkey` configuration. |
| Session Palette | Ctrl+P | Ctrl+P | Intentionally takes Ctrl+P from shell history navigation. |
| Command Palette | Ctrl+Shift+P | Ctrl+Shift+P | Search application commands. |
| Dashboard | Command+Shift+G | Ctrl+Shift+G | Existing local-pane dashboard. |
| Copy | Command+C | Ctrl+Shift+C; Ctrl+Insert | Ctrl+C also copies while a terminal selection exists; otherwise it reaches the process. |
| Paste | Command+V | Ctrl+Shift+V; Shift+Insert; Ctrl+Shift+I | All three invoke the same paste action. |
| Select All | Command+A | Ctrl+Shift+A | Terminal selection. |
| Settings | Command+, | Ctrl+,; Ctrl+Alt+S | Both open Settings. |
| Quit | Command+Q | Alt+F4 | Native window close/quit handling. |
| New Session on Server | None | None | Explicit server menu/control action, separate from Ctrl+N's active-context behavior. |
| Restart Session | None | None | Menu action. |
| Rename Session | None | None | Menu/control action; F2 reaches the terminal. |
| Clear Scrollback | Terminal backend | None | Menu action; Ctrl+Shift+K is removed. |

## Assigned features awaiting Windows implementation

These assignments are documented only: this change does not install placeholder handlers or claim these features work.
Do not reuse their combinations for another standard action. Until implemented, the keys can still reach a terminal
or control; a documented reservation is not a system-wide or runtime registration.

| Feature | macOS default | Windows assignment | Remaining work |
|---|---|---|---|
| New Window | Command+Option+N | None | A standard new-window action. |
| New Workspace | Command+Shift+N | Ctrl+Shift+N | Workspace creation UI/action. |
| Open Directory | Command+O | Ctrl+O | Directory picker and session creation action. |
| Attach Remote | Command+Shift+R | Ctrl+Shift+R | Attach UI/action; no restart alias on this combination. |
| Reopen Recent | Command+Shift+T | Ctrl+Shift+T | Recent closed-session history/action. |
| Undo Close | Command+Z | Ctrl+Shift+Z | Pending-close lifecycle and undo; preserve native text-field undo. |
| MRU session switcher | Ctrl+Tab / Ctrl+Shift+Tab | Ctrl+Tab / Ctrl+Shift+Tab | Snapshot recent sessions, cycle while Ctrl is held, commit on Ctrl release, cancel with Esc, as on macOS. The former immediate sidebar-step bindings are removed now. |
| Previous / next Attention session | Ctrl+Option+Up / Down | Ctrl+Alt+Up / Down | Navigation among sessions needing attention. |
| Terminal Zoom | Command+Shift+Enter | Ctrl+Shift+Enter | Focused-terminal zoom action. |
| Custom Command Palette | Ctrl+Shift+O | Ctrl+Shift+O | Windows custom-command execution and palette. |
| Toggle Flag | Command+Shift+F | Ctrl+Shift+F | Session flags and action. |
| Fullscreen | Command+Ctrl+F | F11 | True fullscreen/window restoration, not maximization. Win+Shift+F is unassigned. |
| Toggle Sidebar | Command+Ctrl+S | None | Sidebar visibility action; Ctrl+Alt+S belongs to Settings. |
| Show Attention | Ctrl+Shift+I | None | Attention overview; Ctrl+Shift+I belongs to Paste. |

## Overrides and retired defaults

No persisted-data migration is needed. `native.json` and saved session data keep their formats. The shipped defaults
change for installations without an explicit override. Existing `keymap.conf` files remain in place: an explicit
binding keeps its chord when a new default would otherwise displace it. Removed defaults are not compatibility aliases;
a user can still explicitly map a supported action to an old combination.

Retired defaults include Ctrl+Shift+T/N/W/F for New Session / New Session on Server / Close Session / Find,
Ctrl+= for increasing font size, Alt+Shift+=/- for splits, Alt+Left/Right for pane focus, F2 for Rename,
Ctrl+Shift+R for Restart, and Ctrl+Shift+K for Clear Scrollback. Ctrl+Shift+J now toggles Overlay instead of Scratch.
Ctrl+Tab no longer steps through sidebar neighbors; its MRU replacement is pending.

Ctrl+D (EOF), Ctrl+J (line feed), and Ctrl+Z (suspend) are not application shortcuts. The fixed editing and Settings
aliases share the same conflict reservations as their primary shortcuts. Text fields, palettes, embedded pages,
and the sidebar have their own focus handling; terminal editing shortcuts are not global accelerators.

## Verification

`WindowsKeymapTests` covers dispatch, retired keys passing through, clipboard aliases, Ctrl+C's selection condition,
and preservation of existing explicit bindings. Menu/palette/title-bar tests check displayed shortcuts. Windows CI's
`panes-ui` case checks split and pane-focus keys; `overlay-keys` checks overlay show/hide and Ctrl+W dismissal.
The existing ARM64 `overlay-keys` skip remains documented in the integration suite; it is not a pass.
