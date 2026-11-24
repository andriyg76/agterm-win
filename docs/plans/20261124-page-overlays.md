# Stage D — page overlays (WebView2)

After [presentation UI](20261124-presentation-ui.md), local and catalog sessions expose the same ctl overlay page
sources as the Mac (`--html`, `--url`, `--image`, `--markdown-file`, `--text-file`). Windows uses WebView2 in the
overlay slot; replica pages follow the same `pageRequest` path as program overlays.

**Order:** **D0** `--url` in a floating panel, then markdown/text/image and presentation replica pages.

## In progress (branch `feature/page-overlays`)

| Milestone | Work | Gate |
|-----------|------|------|
| D0 | WebView2 host (`PageOverlayFrame` + `NativeWebView.cpp`); local `--html` / `--url` | integration `overlay-html` |
| D1 | Remote `pageRequest` / `pageClose` on WSL presenter | `remote-linux-gate` row + smoke when disconnected |
| D2 | markdown/text/image sources | extend `overlay-html` |

## Progress

- [x] D0 scaffold (WebView2 SDK fetch, host HWND, local file + https URL)
- [x] `--html` / `--url` on local sessions (`ControlOverlayOpen` + `NativeControl+Overlay`)
- [ ] D1 replica pages on catalog sessions
- [ ] D2 markdown/text/image