# Remote session exit

When the last shell exits, its session remains selectable as ended. Selecting its sidebar row shows the retained terminal and scrollback, including after visiting another session. Explicit Close Session removes the catalog row and destroys the retained Windows terminal. Split promotion and parent-shell respawn with companions keep their existing behavior.

The buffer belongs to the running Windows client; this change does not persist scrollback across client restarts or recover output for a session the client never attached.

## Upstream comparison

Checked `umputun/agterm` at `3dc9f06a7ffd6cfbdbfec3ecea3cecfede39186e`:

- `agtermCore/Sources/AgtermServerKit/PaneObserver.swift` closes a session after a confirmed last-shell exit, while daemon loss leaves it ended. Retaining a confirmed exit is an intentional behavior change requested for agterm-win and requires updating the server as well as the client.
- `agtermCore/Sources/agtermCore/AppStore+Catalog.swift` already preserves the surfaces of an ended catalog row. Windows now similarly owns a terminal per attached remote session instead of resetting one shared terminal on selection.

The callback change from `21a3318d` that redraws the sidebar on every catalog change is reverted at the user's request. This checkout keeps the earlier catalog callback wiring. Row-removal notifications are deferred until reconciliation finishes so explicit close can release the retained terminal.

## Validation

`PaneObserverTests` covers exit retention, explicit close, daemon loss, split promotion, and companion respawn. `RemoteCatalogMirrorTests` covers retaining ended surfaces.

Stage the changed Windows client and server, set `AGTERM_WIN_GATE_WSL` to the test distribution, and run the Windows integration case `remote-exit-buffer`. It exits a remote shell, visits another session, clicks the ended sidebar row, checks its buffer, and checks that explicit close destroys the terminal window.
