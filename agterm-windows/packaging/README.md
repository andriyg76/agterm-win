# agterm-win packaging

`scripts\release.ps1 -Version <AGTERM_VERSION>.<n> [-Publish]` builds `build\release\agterm-win-<version>-x64-setup.exe`;
the script's header lists the tools and the signing variables.

- **GitHub / winget**: `-Publish` uploads the installer and its `.sha256` to this fork's release `v<version>`.
  A winget manifest points at that asset with `InstallerType: inno`.
- **Microsoft Store**: in Partner Center, an EXE app whose package URL is that release asset (versioned, HTTPS),
  silent switches `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`. The Store requires a signed installer and does not
  update the app; winget or the next installer does.

Linux agterm-server tarballs are not packaged: `--install-server` downloads the one matching `AGTERM_VERSION` from
upstream agterm's release and checks it against `agterm-server.sha256`, which `release.ps1` also checks against the
sha256 sealed into that release's DMG.
