# Stage B — server program overlay on agterm-win

Depends on **stage A** (local program overlay) landing on `windows-port`. Goal: Mac parity for agents — a program
overlay on an **agterm-server catalog session** works like a local overlay, driven by presentation when the server
requests one.

## Behavior

- `RemotePresentationClient` for catalog rows uses `presents: true` (not mirror) once B ships.
- `overlayRequest`: run the job helper over the WSL transport (same pattern as Mac `showReplicaOverlay` /
  `RemoteSession.runJobCommand`), open `OverlayFrame` for the catalog session id, answer `overlayClosed` on the stream.
- `overlayClose` / `overlayResize` from the server match ctl overlay close/resize on that session.
- `session.overlay.*` via agtermctl on a **connected** server session id succeeds; tree shows `overlay`; `serverRefusal` goes away.
- Pages, ask, pick, HUD still refused until stages E / D.

## Implementation sketch

1. `RemoteWindow.startPresentation`: `presents: true`, wire `overlayRequest` / `overlayClose` / `overlayResize` into
   `NativeShell` (per-session presenter client reference for `answer(...)`).
2. `NativeShell`: overlay slot keyed by catalog session id (parallel to `locals[].overlay`); attach/select unchanged;
   `isServerSession` + connected checks in `NativeControl+Overlay`.
3. Job helper: lease control socket path under state dir, build argv via `RemoteSession.runJobCommand` with
   `WSLTransport`, feed command into existing overlay terminal start path.
4. Presentation mode in tree: `presenter` while overlay shown (align with Mac `remote-linux-gate` program overlay row).

## Tests (gate B)

| Layer | What |
|-------|------|
| **agtermCore** | Extend `RemotePresentationClientTests` — `presents: true`, accept overlay, resize, close, `overlayClosed`. |
| **AgtermWinKit** | `NativeControlTests` — open overlay on fake server session when connected. |
| **Integration** | Case `overlay-server-program` — remove SKIP in `run.ps1`; run against a live agterm-server when CI has WSL+server, else gate script / manual `remote-linux-gate` step. |
| **Gate** | `docs/remote-linux-gate.md` program overlay row on Windows viewer when B is done. |

Until B is implemented, integration `overlay-server-program` is listed but **SKIP** in `run.ps1`.

## Progress

- [ ] `presents: true` and presentation effect wiring
- [ ] Server-session overlay state in `NativeShell`
- [ ] Job helper launch over WSL
- [ ] Remove `serverRefusal` for connected sessions
- [ ] Unit + integration gates green on x64
- [ ] Remove arm64 skip only if a keys case is added for server overlays