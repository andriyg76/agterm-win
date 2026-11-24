# agterm-win: session naming, keymap, notifications, settings dialog

Order agreed 2026-11-23: naming → keymap → settings (appearance first) → notifications.
Rule: every feature behaves as it does in agterm on macOS; where agterm-win cannot do part of it yet, it keeps
agterm's behavior for a viewer that cannot (the server holds what no presenter shows) rather than inventing one.
The native Windows server port waits until the client reaches parity with the WSL server.

## 1. Dynamic session naming — done on `claude/nice-einstein-u0a4qh`, not yet verified on Windows

- Local name order is `Session.displayName`'s: custom name, program title, last reported folder, profile name.
- The shim polls `GHOSTTY_TERMINAL_DATA_PWD` beside the title (`nt_take_naming`, `nt_title`, `nt_pwd`).
- Bare `powershell`/`pwsh` profiles get a wrapped prompt (`-NoExit -EncodedCommand`); bare `cmd` gets
  `/k prompt $e]9;9;$P$e\$P$G`, which replaces a custom `PROMPT`.
- WSL profiles name themselves only if their shell emits OSC 0/2 or OSC 7/9;9.
- Check on Windows: `GHOSTTY_TERMINAL_DATA_PWD` exists in the pinned libghostty-vt 1.0.1, ConPTY passes
  OSC 9;9 through, and an oh-my-posh prompt still renders.
- A session renamed in an older build restores with that name as its fallback, so its folder overrides it.

## 2. Keymap — done on `claude/nice-einstein-u0a4qh`, not yet verified on Windows

- `<stateDir>\config\keymap.conf` (`%LOCALAPPDATA%\agterm-win\config`), the Mac format and parser.
  ☰ ▸ Edit Keymap… writes the commented starter when missing; Reload Keymap and startup show problems.
- On Windows `BuiltinAction.defaultChord` is `windowsDefaultChord` (the old `Ctrl+Shift+…`), so the parser's
  conflict rules, the starter file and `keymap.list` see agterm-win's defaults.
- Bindable: new_session, new_remote_session, rename_session, close_session, next/previous_session,
  toggle_search, increase/decrease/reset_font_size. Copy, paste, select all, clear scrollback, restart and Alt+F4
  stay fixed; a binding on one is reported and never fires.
- `cmd` is the Win key: a `WH_KEYBOARD_LL` hook, installed only while a binding uses it, swallows bound Win
  chords with agterm in front and taps VK 0xE8 so Start does not open. `Win+L` cannot be taken.
- Leader sequences work; Esc abandons one; there is no leader timeout yet.
- `command` lines are reported as unsupported and skipped; running them needs the Windows command runner.
- Check on Windows: Win+T with `map cmd+t new_session`, the Start menu staying closed, a hook-hostile security
  product, and a non-US layout's OEM keys.

## 3. Notifications — local sessions done, not yet verified on Windows

- OSC 9/777 carries its title and body out of the shim (`nt_take_notification`); the bell stays a ● marker and a
  flash, not a notification, as on macOS.
- NotificationRules: a terminal notification from the session in view with agterm in front is dropped
  (`TerminalNotification.shouldDeliver`); `notify` never is. Terminal and `notify` banners replace only their own
  last one (tag), grouped by session.
- Banners are Windows toasts through the WinRT ABI (`NativeToast.cpp`). An MSIX uses its identity; any other
  install registers `andriyg76.agterm-win` under `HKCU\Software\Classes\AppUserModelId` with the staged
  `agterm.png` and sets it as the process AppUserModelID; the Inno shortcut carries the same ID.
- Clicking a banner brings agterm forward with the session selected; selecting a session clears its ● count and
  removes its banners from Action Center.
- Settings ▸ Notifications: banners, sound, the count beside ●, taskbar flash (off / once / until in front,
  default until in front, the behavior before this setting).
- `notify` replies with `ControlNotify.bannersOffNote` while banners are off; `tree` reports `unseen`.
- agterm-server sessions: as on a Mac, every catalog row opens its `zmx present` stream (`RemoteWindow`), which
  brings the server's `notify`. It is a mirror (`RemotePresentationClient.presents` false) until agterm-win shows
  asks, picks, HUD, overlays and pages, so the server keeps those waiting as it does while no Mac shows the session. A
  server program's OSC 9/777 travels as bytes in the attached pane, so it reaches agterm-win only from the session
  the shared server terminal shows; a background server session's OSC needs a terminal per server session.

## 4. Settings — Appearance done locally, not yet verified on Windows

- ☰ ▸ Settings… (Ctrl+, fixed) opens one window; its Appearance group holds the theme, the dark-mode theme with
  "Follow Windows light and dark mode", the font family (installed monospaced fonts) and the size.
  Every change previews on all terminals; OK saves to `native.json`, Cancel and close restore.
- Themes are ghostty theme files: 34 bundled from iTerm2-Color-Schemes `86a776d` (the commit ghostty's themes
  release names) plus agterm's own, in `Resources/themes`, staged as `themes\`; `<config>\themes` adds or
  overrides by name. Names match the macOS app, so `theme = Dracula` means the same on both.
- The shim sets libghostty-vt's default colors, cursor and palette (unset entries keep the built-in palette);
  the cursor draws in the effective cursor color, selection in the theme's selection background.
- `theme.list` / `theme.set NAME | --light L --dark D | --dark none` match the macOS command and read-back.
- Not yet: the sidebar and window chrome keep their dark colors; selection-foreground is not applied; a Settings
  window open during `theme.set` keeps showing its own values.
- Settings is now three tabs, as on macOS: General, Appearance, Notifications.
- `agtermctl settings open [tab]` (`settings.open`) shows a tab; no command reads or writes a setting (see control-api.md).
- General, from macOS's General where it applies: where a new session opens (home, the selected session's folder,
  or a folder), where it goes (end, after the selected one), asking before closing a local session, right-click
  pastes (off: Windows keeps its menu, Shift+right-click opens it when on), lines a wheel notch scrolls, and the WSL
  distribution agterm-server runs in (next start; `--wsl` wins). `session new --cwd` now starts there.
- Not on General yet: restore mode (agterm-win restores fresh shells in their last folder; live would need a local
  zmx per session, re-run a foreground-command reader) and opening links in an overlay (no page overlays yet).

## Presentation and overlays — Mac parity for agents (2026-11-24)

**Goal:** the same `agtermctl` session and overlay commands work for local sessions and agterm-server (WSL) sessions; agents
must not special-case Windows. WSL stays transport to the server; the viewer must **present**, not only mirror.

**Order (do not reorder): A → B → E → D.** Each stage is not done until its tests are in CI (or documented skip) and green
on x64; the next stage does not start before that.

| Stage | What | Primary tests |
|-------|------|----------------|
| **A** | Local program overlay | `AgtermWinKitTests`, integration `overlay` / `overlay-keys` |
| **B** | Server program overlay | `agtermCore` presentation + integration `overlay-server-program` |
| **E** | Ask, pick, HUD (`presents: true`) | `agtermCore` + integration per surface |
| **D** | Page overlays (HTML/URL/…) | `agtermCore` + integration `overlay-html` (+ remote gate rows) |

### Stage A — local program overlay (CI green on PR #26, 2026-11-24)

- `session.overlay.open|close|resize|result|text|copy|hide|show|toggle` on a **local** session; `NativeControl+Overlay.swift`
  owns refusals and read-back (`overlay`, `overlaySizePercent`, `hiddenOverlays`).
- ConPTY in `OverlayFrame`; full area or floating `--size-percent`; session program keeps running.
- Launch: `cmd.exe /d /s /c` on Windows profiles; `wsl.exe -d D --cd DIR --exec sh -c` when the **local** session is WSL.
- Refused until later stages: pages, `--pane`, `--width`/`--height`, **agterm-server catalog sessions** (`serverRefusal`).
- Not yet: translucent chrome (Mac parity).

**Tests (gate A):**

- **Unit** (`swift test` in `agterm-windows`): `NativeControlTests` overlay commands, refusals, tree projection;
  `NativeOverlayTests` launch quoting, panel geometry, WSL command lines.
- **Integration** (`tests/integration/run.ps1` on x64): case `overlay` (ctl open/hide/result/`--wait`); case
  `overlay-keys` (Close Session dismisses overlay, key closes exited `--wait`).
- **Integration (arm64):** same cases; `overlay-keys` may be **SKIP** on native ARM64 until focus/chord matches x64
  (see `tests/integration/README.md` — Architecture skips).
- **Manual before merge when touching keys/focus:** floating panel over a TUI; DPI with overlay open; Ctrl+Shift+W
  then second chord closes session only.

### Stage B — server program overlay (next after A merges)

- `RemotePresentationClient.presents = true` for server sessions agterm-win shows; handle `overlayRequest`, run job in
  the same `OverlayFrame` path as A; answer resize / close / closed on the presentation stream.
- Remove `serverRefusal` for program overlay when the server is connected; `tree` reports `overlay` on server session nodes.
- Still refuse asks, picks, HUD and pages until stage E / D.

**Tests (gate B — add with the stage, all required on x64 CI):**

- **Unit (`agtermCore`):** extend `RemotePresentationClientTests` for `presents: true` + `overlayRequest`: job start,
  resize, explicit close, process exit → `closed` with exit code (reuse fixtures already used with `presents: false`).
- **Unit (`AgtermWinKit`):** `NativeControlTests` opens overlay on a fake **server** session when host reports connected;
  refusal when disconnected or unknown id unchanged.
- **Integration:** new case `overlay-server-program` in `shell-cases.ps1` or `wsl-cases.ps1`: start or attach to an
  agterm-server workspace session (same constraints as future WSL server CI — when only synthetic WSL is available, gate
  on ctl + log: `presentation` mode `presenter`, `session.overlay.open` on server id succeeds, `overlay` in tree,
  `session.overlay.text` reads program output, `session.overlay.close` clears tree; session row remains). Until a live
  server runs on the runner, keep a **manual** row in `docs/remote-linux-gate.md` mirroring Mac gate overlay lines.
- **Negative:** overlay on server session while catalog disconnected returns the same errors as Mac, not a hang.

### Stage E — presentation UI: ask, pick, HUD (after B)

Presentation stays on; add viewer surfaces in precedence order (match Mac `AppActions` / pick registry). Program overlay
from B remains; no HTML yet.

**Tests (gate E — one integration case per sub-milestone, x64 CI):**

| Sub | Behavior | Tests |
|-----|----------|--------|
| **E1** | Ask modal; cancel/answer; presentation lost → ctl exit 2 | `agtermCore` ask dispatch; integration `presentation-ask` |
| **E2** | Pick UI; choice reaches server | `SessionPickTests` patterns; integration `presentation-pick` |
| **E3** | HUD overlay slot; dismiss does not close session | `agtermCore` HUD messages; integration `presentation-hud` |

- **Tree:** `presentation.state` / mode reads `presenter` while any of the above is active (extend existing WSL/server
  checks if present).
- **Regression:** stage A/B integration cases still pass with `presents: true`.

### Stage D — page overlays (after E)

- Local and server sessions: `--html`, `--url`, `--image`, `--markdown-file`, `--text-file` (WebView2 on Windows, same
  ctl surface as Mac WKWebView); navigation policy and refusals from `agtermCore` first, adapter second.
- General «open link in overlay» can ship as **D0** (`--url` only) before full markdown/text/log pages.

**Tests (gate D):**

- **Unit (`agtermCore`):** dispatcher + projection for page overlay args (already on Mac); Windows refuses until adapter
  exists — flip tests from refusal to success per feature.
- **Integration (`overlay-html`):** local session, `--html` file on disk, visible text in snapshot, `overlay.close`,
  Command-W / ctl parity smoke.
- **Integration (`overlay-url`):** optional D0; external https or loopback per security policy (align
  `docs/remote-linux-gate.md` loopback refusal on server host).
- **Remote gate:** add rows equivalent to Mac overlay URL/HTML checks when server presentation is live.

### Deferred (not A–D)

- Split `--pane`, `--width`/`--height`, translucent overlay chrome.
- Font ligatures (below).

## Later: font ligatures

Deferred 2026-11-23. The renderer maps one codepoint to one glyph (`GetGlyphIndices`, `NativeShim.cpp`), so
`=>`, `!=`, `->` never join; macOS has them through ghostty (`calt`/`liga` on, `font-feature` to turn off).

- Shape runs of same-style cells with `IDWriteTextAnalyzer::GetGlyphs` and pin each cluster to the cells it
  covers.
- Break a ligature the cursor or a selection edge falls inside, as ghostty does.
- "Font ligatures" in Settings ▸ Appearance, on by default, saved in `native.json`.
- Shape only changed rows and cache the result; per-frame shaping costs the paint.

The Font list holds only fonts DirectWrite flags monospaced; a monospaced font missing the flag needs a typed
name, if one turns up.
