# Stage E — presentation UI (ask, pick, HUD)

After [stage B](20261124-server-program-overlay.md), agterm-win keeps `presents: true` on catalog streams and adds viewer
surfaces in order: **E1 ask**, **E2 pick**, **E3 HUD**. Page overlays stay in stage D.

## E1 — replica ask

- `RemoteWindow`: `askRequest` / `askDismiss`.
- `NativeShell`: session-wide, terminal-style, button-only asks via `presentReplicaAsk` and `nt_ask_choice`; refuse GUI,
  pane-targeted, and form asks until a fuller dialog exists.

## E2 — replica pick

- `PickRegistry` + `PickController` on the sole shell window.
- `SessionPickBook.openReplica` with the command palette listing items (`Palette.Target.pickChoice`).
- Queued picks drain when the modal slot frees; cancel on palette dismiss sends `pickRejected`.

## E3 — replica HUD

- `markViewerHud` / `closeBridgedHud` for catalog tree read-back.
- Passive `STATIC` panel over the remote terminal; auto-hide from origin `remaining` or `hideAfter`.
- Refused while a program overlay occupies the slot (unless updating a bridged HUD).

**Integration:** `presentation-ask`, `presentation-pick`, and `presentation-hud` are not in CI yet — need live server
scripts and `AGTERM_WIN_GATE_WSL` (see `docs/remote-linux-gate.md`).

## Progress

- [x] E1 wiring + Task Dialog for simple replica asks
- [x] E2 palette pick + `SessionPickBook` replica path
- [x] E3 bridged HUD panel + auto-hide
- [ ] Integration gates per surface on x64 CI or documented manual gate