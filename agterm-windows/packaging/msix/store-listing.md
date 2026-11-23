# Microsoft Store listing (en-US)

Paste into Partner Center ▸ Store listings ▸ English. Keep it to what the shipped build does.

## Short description

A native Windows terminal with a session sidebar and a full control API. Run PowerShell, cmd and WSL side by
side, keep long-lived Linux sessions running in WSL, and drive it all from scripts and coding agents with
agtermctl.

## Description

agterm-win is the Windows port of agterm: a simply good terminal with a full control API.

Running several shells, servers and coding agents at once means many long-lived sessions, and a row of tabs
loses track of them quickly. agterm-win keeps them in a sidebar instead, each with a name that follows what it
is doing, so the one that needs you is easy to find.

Local sessions
Start Windows PowerShell, PowerShell 7, Command Prompt or any WSL distribution from a launch profile. A session
names itself after its program's title or the folder it is in, or keeps a name you give it. Sessions open at
quit start again next time, in the folder they were last in.

Sessions that keep running in WSL
agterm-win connects to agterm-server inside a WSL distribution and shows its workspaces and sessions in the same
sidebar. Those shells keep running when agterm-win closes, and come back with their screen when it opens again.
One command installs the server, checked against a hash built into the app.

Built for scripts and agents
The bundled agtermctl drives agterm-win over a local socket: list sessions, start, rename, restart or close
them, type into one, read its screen back, post a notification to it, change the font size, and read or reload
the keymap. A script or a coding agent can set up and watch its own sessions without you.

A capable everyday terminal
- Fast native rendering with Direct2D and DirectWrite, on the terminal engine from Ghostty (libghostty-vt).
- Search the scrollback, select by word or line, copy and paste with bracketed paste.
- Click web links to open them in your browser; drop files to type their paths, as Linux paths in WSL.
- Mouse reporting for full-screen programs, and a marker plus a taskbar flash when a background session rings
  or notifies.
- Rebind every built-in shortcut in keymap.conf, the same file format agterm uses on macOS, leader sequences
  and Win-key chords included.

Private by design
No account, no telemetry, no analytics. agterm-win goes online only when you ask it to install agterm-server.

## What's new in this version

- Sessions name themselves after their program's title or current folder, and restore in that folder.
- Shortcuts come from keymap.conf, with Edit Keymap and Reload Keymap in the menu.

## Product features (one per line, up to 20)

Session sidebar for PowerShell, PowerShell 7, Command Prompt and WSL
Session names that follow the program's title or current folder
Sessions reopen at the next launch in the folder they were last in
Long-lived WSL sessions through agterm-server that survive closing the app
agtermctl command-line control: create, rename, type into and read sessions
Native Direct2D rendering on Ghostty's terminal engine
Scrollback search, word and line selection, bracketed paste
Clickable web links and drag-and-drop file paths
Attention marker and taskbar flash for background sessions
Rebindable shortcuts in keymap.conf, including leader sequences and Win-key chords
No account, no telemetry, no analytics

## Search terms (up to 7)

terminal
PowerShell
WSL
console
command line
developer tools
coding agents

## Other fields

- Category: Developer tools
- Privacy policy URL: https://github.com/andriyg76/agterm-win/blob/windows-port/agterm-windows/PRIVACY.md
- Website: https://github.com/andriyg76/agterm-win
- Support contact: https://github.com/andriyg76/agterm-win/issues
- Minimum OS: Windows 10 version 1903 (build 18362), as the package manifest requires.
