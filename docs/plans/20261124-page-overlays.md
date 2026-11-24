# Stage D — page overlays (WebView2)

After [presentation UI](20261124-presentation-ui.md), local and catalog sessions expose the same ctl overlay page
sources as the Mac (`--html`, `--url`, `--image`, `--markdown-file`, `--text-file`). Windows uses WebView2 in the
overlay slot; replica pages follow the same `pageRequest` path as program overlays.

**Order:** **D0** `--url` in a floating panel, then markdown/text/image and presentation replica pages.

## Not started

| Milestone | Work | Gate |
|-----------|------|------|
| D0 | WebView2 host in `OverlayFrame` or sibling HWND; `session.overlay.open --url` on **local** sessions | integration `overlay-html` (minimal file on disk) |
| D1 | Remote `pageRequest` / `pageClose` on WSL presenter | `remote-linux-gate` row + smoke when disconnected |
| D2 | markdown/text/image sources | extend `overlay-html` |

## Progress

- [ ] D0 scaffold (dependency + empty host)
- [ ] Remove `NativeOverlay.pageRefusal` for supported sources incrementally