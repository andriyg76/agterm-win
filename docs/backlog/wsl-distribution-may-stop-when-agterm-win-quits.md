---
worth: maybe
where: agterm-windows/Sources/agterm-win/NativeShell.swift:startServer
added: 2026-11-24
---
# a WSL distribution may stop, with its agterm-server, once agterm-win quits

agterm-win reaches a distribution's agterm-server only through `wsl.exe` pipes: the catalog stream, the presentation
streams and the shown pane's `zmx attach`. Sessions live in the distribution's own zmx daemons, as on a Linux host. The server process itself needs no
keeping: each daemon runs in a systemd scope of its own (`ServerPlacement`), and a restarted server adopts the
survivors (`AgtermServer.adopt`). What a session cannot survive is the distribution stopping, daemons included.
Unverified: WSL2 may stop a distribution once no `wsl.exe` client is left and its idle timeout passes, systemd and
lingering or not. Then quitting agterm-win ends the server and every session in it, which a Linux host never does.

Check: start a server from agterm-win, quit it, wait about two minutes, then `wsl -l -v`. `Running` closes this
entry. `Stopped` calls for a keep-alive that outlives agterm-win, started only once the user starts that server:
a local `zmx.exe` daemon running `wsl.exe -d <distribution> -e sleep infinity`, which a later launch finds by name
and a server stop ends. Decided 2026-11-24 to leave it as is until checked.
