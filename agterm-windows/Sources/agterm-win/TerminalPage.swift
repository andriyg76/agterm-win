/// The page the window shows: a sidebar of the server's workspaces and sessions beside one xterm.js terminal.
/// Every message is a JSON object with a `t` kind. To the page: `out` (base64 bytes in `d`), `reset`, `tree`
/// (`workspaces`, `selected`, `notice`). From the page: `ready`/`resize` (`cols`, `rows`), `in` (typed text in
/// `d`), `title`, `select` (session `id`).
enum TerminalPage {
    // pinned CDN builds for now; a release bundles them and maps a virtual host instead
    static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css">
    <style>
      :root { --bg: #1e1e1e; --side: #252526; --text: #cccccc; --dim: #858585; --sel: #37373d; --accent: #0e639c; }
      html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text); overflow: hidden;
                   font: 13px "Segoe UI", system-ui, sans-serif; }
      #sidebar { position: absolute; left: 0; top: 0; bottom: 0; width: 220px; background: var(--side);
                 overflow-y: auto; user-select: none; }
      #notice { padding: 8px 12px; color: var(--dim); }
      .workspace { padding: 10px 12px 4px; color: var(--dim); font-size: 11px; text-transform: uppercase;
                   letter-spacing: .04em; }
      .session { padding: 4px 12px 4px 20px; cursor: default; white-space: nowrap; overflow: hidden;
                 text-overflow: ellipsis; }
      .session:hover { background: #2a2d2e; }
      .session.selected { background: var(--sel); box-shadow: inset 2px 0 var(--accent); }
      .session.ended { color: var(--dim); font-style: italic; }
      #terminal { position: absolute; left: 226px; right: 6px; top: 6px; bottom: 6px; }
    </style>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js"></script>
    </head><body>
    <div id="sidebar"><div id="notice">connecting…</div><div id="tree"></div></div>
    <div id="terminal"></div><script>
      const send = (o) => window.chrome.webview.postMessage(JSON.stringify(o));
      const term = new Terminal({ fontFamily: "'Cascadia Mono', Consolas, monospace", fontSize: 14,
                                  cursorBlink: true, scrollback: 10000, allowProposedApi: true });
      const fit = new FitAddon.FitAddon();
      term.loadAddon(fit);
      const host = document.getElementById("terminal");
      term.open(host);
      fit.fit();
      term.onData((d) => send({ t: "in", d }));
      term.onResize(({ cols, rows }) => send({ t: "resize", cols, rows }));
      term.onTitleChange((title) => send({ t: "title", title }));
      new ResizeObserver(() => fit.fit()).observe(host);

      const tree = document.getElementById("tree"), notice = document.getElementById("notice");
      function renderTree(m) {
        notice.textContent = m.notice || "";
        notice.style.display = m.notice ? "" : "none";
        tree.replaceChildren();
        for (const w of m.workspaces) {
          const head = document.createElement("div");
          head.className = "workspace";
          head.textContent = w.name;
          tree.append(head);
          for (const s of w.sessions) {
            const row = document.createElement("div");
            row.className = "session" + (s.id === m.selected ? " selected" : "") + (s.ended ? " ended" : "");
            row.textContent = s.name;
            row.title = s.name;
            row.onclick = () => { send({ t: "select", id: s.id }); term.focus(); };
            tree.append(row);
          }
        }
      }

      window.chrome.webview.addEventListener("message", (e) => {
        const m = JSON.parse(e.data);
        if (m.t === "out") {
          const raw = atob(m.d);
          const bytes = new Uint8Array(raw.length);
          for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
          term.write(bytes);
        } else if (m.t === "reset") {
          term.reset();
        } else if (m.t === "tree") {
          renderTree(m);
        }
      });
      send({ t: "ready", cols: term.cols, rows: term.rows });
      term.focus();
    </script></body></html>
    """
}
