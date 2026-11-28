# Microsoft Store listing (en-US)

Paste into Partner Center ▸ Store listings ▸ English. This listing covers agterm-win 0.44.1.11 (MSIX version
0.44.1011.0) and later.

The Store title and the package's `DisplayName` are still the reserved name `agterm`. To show `agterm-win`, reserve
that name under Product management ▸ Product identity first, then change `DisplayName` in both
`AppxManifest*.xml` files (the `<Properties>` element and `uap:VisualElements`); a package whose display name is not
reserved fails certification.

## Short description

A native Windows terminal with a workspace and session sidebar and a full control API. Run PowerShell, Command
Prompt, Git Bash and WSL side by side, keep sessions running after the app closes, and drive it all from scripts and
coding agents with agtermctl.

## Description

agterm-win is the Windows port of agterm: a simply good terminal with a full control API.

Running several shells, servers and coding agents at once means many long-lived sessions, and a row of tabs loses
track of them quickly. agterm-win keeps them in a sidebar instead, grouped in workspaces, each with a name that
follows what it is doing and a status dot that shows which agent needs you.

Sessions for every shell
Start Windows PowerShell, PowerShell 7, Command Prompt, Git Bash or any WSL distribution from a launch profile, or
add your own in profiles.properties. A session names itself after its program's title or the folder it is in, or
keeps a name you give it. Split it, open a scratch shell over it, or jump to any session from the palette.

Sessions that keep running
With Live sessions turned on, local shells keep running when agterm-win closes and come back with their screen
when it opens again. Sessions on agterm-server inside a WSL distribution keep running in Linux the same way. One
click installs the server, checked against a hash built into the app.

Built for scripts and coding agents
The bundled agtermctl drives agterm-win over a local socket with the same control API agterm has on macOS: create,
rename, restart or close sessions, type into one, read its screen back, post a notification to it, and read or
reload the keymap. Claude Code and Codex report active, blocked and finished on their session's status dot, so you
see which of many agents is waiting on you.

A capable everyday terminal
- Fast native rendering with Direct2D and DirectWrite, on the terminal engine from Ghostty (libghostty-vt).
- Search the scrollback, select by word or line, copy and paste with bracketed paste.
- Click web links to open them in your browser; drop files to type their paths, as Linux paths in WSL.
- Mouse reporting for full-screen programs, and a marker plus a taskbar flash when a background session rings or
  notifies.
- Rebind every built-in shortcut in keymap.conf, the same file format agterm uses on macOS, leader sequences and
  Win-key chords included.

Private by design
No account, no telemetry, no analytics. agterm-win goes online only when you ask it to install agterm-server. To
show agent status it adds hooks to Claude Code's and Codex's settings, saving a backup of each file first.

Open source under the MIT license: github.com/andriyg76/agterm-win

## What's new in this version

- Live sessions: with Settings ▸ General ▸ Restore sessions set to Live sessions, local shells keep running after
  agterm-win closes and reattach with their screen. A Store update ends them; WSL server sessions survive it.
- Git Bash launch profile, and your own profiles in profiles.properties (Settings ▸ Edit Launch Profiles…).
- Local sessions sit in workspaces, as in agterm on a Mac.
- Claude Code and Codex status on the sidebar's session dots.
- Close button on HTML page overlays, and many sidebar and menu fixes.

## Product features (one per line, up to 20)

Workspace and session sidebar for PowerShell, PowerShell 7, Command Prompt, Git Bash and WSL
Live sessions: local shells keep running after the app closes and reattach with their screen
Long-lived WSL sessions on agterm-server that survive closing the app
agtermctl command-line control with the same API as agterm on macOS
Claude Code and Codex status on each session's sidebar dot
Session names that follow the program's title or current folder
Custom launch profiles in profiles.properties
Splits, scratch shells and a session palette
Native Direct2D rendering on Ghostty's terminal engine
Native x64 and ARM64 builds
Scrollback search, word and line selection, bracketed paste
Clickable web links and drag-and-drop file paths
Attention marker and taskbar flash for background sessions
Rebindable shortcuts in keymap.conf, including leader sequences and Win-key chords
No account, no telemetry, no analytics
Open source under the MIT license

## Search terms (up to 7)

terminal
PowerShell
WSL
Git Bash
command line
Claude Code
coding agents

## Other fields

- Category: Developer tools
- Privacy policy URL: https://github.com/andriyg76/agterm-win/blob/windows-port/agterm-windows/PRIVACY.md
- Website: https://github.com/andriyg76/agterm-win
- Support contact: https://github.com/andriyg76/agterm-win/issues
- Minimum OS: Windows 10 version 1903 (build 18362), as the package manifest requires.

## Restricted capabilities (Submission ▸ Properties)

Partner Center asks why the package declares each restricted capability in `AppxManifest.xml`. See
[STORE-SUBMISSION.md](STORE-SUBMISSION.md) for the submission checklist; the production manifest declares
**runFullTrust** only (Store policy 10.6.3, no `unvirtualizedResources`).

### runFullTrust

agterm-win is a desktop terminal emulator, packaged from a Win32 application (EntryPoint
Windows.FullTrustApplication). Its purpose is to run the user's own command-line programs: it starts Windows
PowerShell, PowerShell 7, Command Prompt, Git Bash and WSL distributions under a Windows pseudoconsole
(CreatePseudoConsole and CreateProcess), passes their input and output, and starts and stops them as the user opens
and closes sessions. With Live sessions it runs its bundled zmx to keep a session's shell running between starts.
It runs wsl.exe to connect to its companion server inside WSL, and runs curl.exe only when the user asks it to
install that server. It also ships agtermctl, a console command exposed as an execution alias, which scripts use to
control the terminal over a local socket under %USERPROFILE%\.local\state\agterm-win, outside the virtualized
profile so a packaged app and an unpackaged agtermctl reach the same path. All of this needs the full-trust desktop
model: an AppContainer process cannot create pseudoconsoles or launch arbitrary user programs with the user's
normal rights. User programs started inside a session keep their normal profile and AppData; agterm-win keeps its own
settings in %USERPROFILE%\.local\state\agterm-win and %USERPROFILE%\.config\agterm, so every install type shares
them. On its first start it adds agent status hooks to the user's Claude Code and Codex
settings, backing each file up first. agterm-win collects no data and makes no network connections of its own
beyond the optional agterm-server install the user starts.
