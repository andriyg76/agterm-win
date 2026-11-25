# Microsoft Store listing (en-US)

Paste into Partner Center ▸ Store listings ▸ English. This listing covers agterm-win 0.44.1.4 (MSIX version 0.44.1004.0).

## Short description

A native Windows terminal with a session sidebar and a full control API. Run PowerShell, cmd and WSL side by
side, keep long-lived Linux sessions running in WSL, and drive it all from scripts and coding agents with
agtermctl.

## Description

agterm is a native Windows terminal with a full control API.

Running several shells, servers and coding agents at once means many long-lived sessions, and a row of tabs
loses track of them quickly. agterm keeps them in a sidebar instead, each with a name that follows what it
is doing, so the one that needs you is easy to find.

Local sessions
Start Windows PowerShell, PowerShell 7, Command Prompt or any WSL distribution from a launch profile. A session
names itself after its program's title or the folder it is in, or keeps a name you give it. Sessions open at
quit start again next time, in the folder they were last in.

Sessions that keep running in WSL
agterm connects to agterm-server inside a WSL distribution and shows its workspaces and sessions in the same
sidebar. Those shells keep running when agterm closes, and come back with their screen when it opens again.
One command installs the server, checked against a hash built into the app.

Built for scripts and agents
The bundled agtermctl controls agterm over a local socket: list sessions, start, rename, restart or close
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
No account, no telemetry, no analytics. agterm goes online only when you ask it to install agterm-server.

## What's new in this version

- Native ARM64 support for Windows on Arm, alongside x64.
- Sessions name themselves after their program's title or current folder, and restore in that folder.
- Shortcuts come from keymap.conf, with Edit Keymap and Reload Keymap in the menu.

## Product features (one per line, up to 20)

Session sidebar for PowerShell, PowerShell 7, Command Prompt and WSL
Session names that follow the program's title or current folder
Sessions reopen at the next launch in the folder they were last in
Long-lived WSL sessions through agterm-server that survive closing the app
agtermctl command-line control: create, rename, type into and read sessions
Native Direct2D rendering on Ghostty's terminal engine
Native x64 and ARM64 builds
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

## Restricted capabilities (Submission ▸ Properties)

Partner Center asks why the package declares each restricted capability in `AppxManifest.xml`. After a denial of
`unvirtualizedResources` (2026-11-25, product 9N0DD68BCXZX), see [STORE-SUBMISSION.md](STORE-SUBMISSION.md) for
reconsideration text, required URLs, and what not to change in the production manifest.

### runFullTrust

agterm is a desktop terminal emulator, packaged from a Win32 application (EntryPoint Windows.FullTrustApplication).
Its purpose is to run the user's own command-line programs: it starts Windows PowerShell, PowerShell 7, Command
Prompt and WSL distributions under a Windows pseudoconsole (CreatePseudoConsole and CreateProcess), passes their
input and output, and starts and stops them as the user opens and closes sessions. It runs wsl.exe to connect to
its companion server inside WSL, and runs curl.exe only when the user asks it to install that server. It also
ships agtermctl, a console command exposed as an execution alias. Scripts use it to control the terminal over a
local socket in the user's AppData. All of this needs the full-trust desktop model: an AppContainer process cannot
create pseudoconsoles or launch arbitrary user programs with the user's normal rights. agterm collects no data
and makes no network connections of its own beyond that install, which the user starts.

### unvirtualizedResources

agterm turns off file-system and registry write virtualization (desktop6:FileSystemWriteVirtualization and
RegistryWriteVirtualization disabled) because the programs it runs are the user's own tools, not part of the
package. When a user runs git, npm, pip, ssh, an editor or a coding agent in agterm, those tools write their
configuration, credentials and caches to the user's real AppData and HKCU, for example %APPDATA%\npm,
.gitconfig-related settings or PowerShell profiles. With virtualization on, those writes would land in a private
package copy. The same tools run from any other terminal would not see them, and uninstalling agterm would
silently delete the user's work. Turning virtualization off makes a program behave exactly as it does in Windows
Terminal or a console window. agterm's own settings are stored in %LOCALAPPDATA%\agterm-win. Nothing is written
outside the user's profile, and no elevated access is requested.

WSL catalog sessions need that same real profile layout: agterm connects with wsl.exe, may download agterm-server
from GitHub when the user chooses Install, and keeps state and the agtermctl control socket under the user's
%LOCALAPPDATA%\agterm-win (not a package-private redirect). A virtualized package would break WSL reconnect,
agtermctl from scripts, and parity with the winget and Inno builds users already run.
