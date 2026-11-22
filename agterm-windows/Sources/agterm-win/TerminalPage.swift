/// The page the window shows: one xterm.js terminal. Output arrives as base64 strings, everything else the page
/// sends is a JSON object with a `t` kind: `ready`/`resize` carry `cols`/`rows`, `in` carries typed text in `d`.
enum TerminalPage {
    // pinned CDN builds for the first milestone; a release bundles them and maps a virtual host instead
    static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css">
    <style>
      html, body { margin: 0; height: 100%; background: #1e1e1e; overflow: hidden; }
      #terminal { position: absolute; inset: 6px; }
    </style>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js"></script>
    </head><body><div id="terminal"></div><script>
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
      window.chrome.webview.addEventListener("message", (e) => {
        const raw = atob(e.data);
        const bytes = new Uint8Array(raw.length);
        for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
        term.write(bytes);
      });
      send({ t: "ready", cols: term.cols, rows: term.rows });
      term.focus();
    </script></body></html>
    """
}
