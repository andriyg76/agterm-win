# agterm-win: session naming, keymap, notifications, settings dialog

Order agreed 2026-11-23: naming → keymap → notifications → settings dialog.
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

## 3. Notifications

- Windows toast through `ToastNotificationManager` with an AppUserModelID: MSIX has one; the Inno installer adds
  a Start Menu shortcut carrying it.
- Pass the OSC 9/777 title and body from the shim's desktop-notification callback (today only `attention` is set).
- Deliver under `TerminalNotification.shouldDeliver`; a click selects the session; `agtermctl notify` posts the same.

## 4. Settings dialog

- Win32 PropertySheet: General, Appearance (font, size), Notifications, Keys (effective bindings, Edit keymap.conf).
- Backed by `NativeSettings`; every setting stays readable through the control API.
