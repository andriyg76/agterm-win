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

## 2. Keymap

- Reuse `agtermCore`'s `parseKeymap`/`KeymapStore` and the Mac `keymap.conf` format, read from the state dir's
  config folder.
- `cmd` means the Win key. Built-in defaults stay on `Ctrl+Shift+…`; only Win chords a user binds go through a
  `WH_KEYBOARD_LL` hook. `Win+L` and other secure chords cannot be taken.
- Map `BuiltinAction` to `NativeMenu.Command`; menus show the effective chord; diagnostics surface like the Mac's.
- Control: `keymap reload` and read-back of the effective chords.

## 3. Notifications

- Windows toast through `ToastNotificationManager` with an AppUserModelID: MSIX has one; the Inno installer adds
  a Start Menu shortcut carrying it.
- Pass the OSC 9/777 title and body from the shim's desktop-notification callback (today only `attention` is set).
- Deliver under `TerminalNotification.shouldDeliver`; a click selects the session; `agtermctl notify` posts the same.

## 4. Settings dialog

- Win32 PropertySheet: General, Appearance (font, size), Notifications, Keys (effective bindings, Edit keymap.conf).
- Backed by `NativeSettings`; every setting stays readable through the control API.
