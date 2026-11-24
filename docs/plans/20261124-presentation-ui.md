# Stage E — presentation UI (ask, pick, HUD)

After [stage B](20261124-server-program-overlay.md), agterm-win keeps `presents: true` on catalog streams and adds viewer
surfaces in order: **E1 ask**, **E2 pick**, **E3 HUD**. Page overlays stay in stage D.

## E1 — replica ask (in progress)

- `RemoteWindow`: `askRequest` / `askDismiss` on the presentation effects.
- `NativeShell`: session-wide, terminal-style, button-only asks via `presentReplicaAsk` and `nt_ask_choice`; refuse GUI,
  pane-targeted, and form asks until a fuller dialog exists.
- **Integration `presentation-ask`:** not in CI yet — needs live server ask like Mac `remote-linux-gate` rows.

## E2 / E3 — not started

| Sub | Work |
|-----|------|
| E2 | `pickRequest`, pick UI, `presentation-pick` |
| E3 | `hud` effect, overlay slot, `presentation-hud` |

## Progress

- [x] E1 wiring + Task Dialog for simple replica asks
- [ ] E1 integration gate (`presentation-ask`)
- [ ] E2 pick
- [ ] E3 HUD