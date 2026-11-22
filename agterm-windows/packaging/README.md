# agterm-win packaging

A `v<AGTERM_VERSION>.<n>` tag runs `.github/workflows/windows-release.yml`, which builds the installer with
`scripts\release.ps1`, has SignPath sign it, and publishes the release. `scripts\release.ps1 -Version <version>
[-Publish]` does the same locally; its header lists the tools and the signing variables.

- **GitHub / winget**: `-Publish` uploads the installer and its `.sha256` to this fork's release `v<version>`.
  A winget manifest points at that asset with `InstallerType: inno`.
- **Microsoft Store**: in Partner Center, an EXE app whose package URL is that release asset (versioned, HTTPS),
  silent switches `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`. The Store requires a signed installer and does not
  update the app; winget or the next installer does.

Linux agterm-server tarballs are not packaged: `--install-server` downloads the one matching `AGTERM_VERSION` from
upstream agterm's release and checks it against `agterm-server.sha256`, which `release.ps1` also checks against the
sha256 sealed into that release's DMG.

## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

- Committers and reviewers: [andriyg76](https://github.com/andriyg76)
- Approvers: [andriyg76](https://github.com/andriyg76)

Only the installer built by `windows-release.yml` on a GitHub-hosted runner from a tag in this repository is signed,
and every signing request is approved by hand.

Privacy: this program will not transfer any information to other networked systems unless specifically requested by
the user or the person installing or operating it. The installer downloads the Microsoft Edge WebView2 runtime
only when it is missing, and `--install-server` downloads agterm-server from GitHub only when run.

### Setting SignPath up

1. Publish one unsigned release first (push a tag with no SignPath variables set): SignPath signs only projects
   already released in the form to be signed. Link this section from the repository's home page and its releases.
2. Apply at https://signpath.org/apply. Ask there whether the Swift runtime and MSVC runtime DLLs the installer
   carries count as system libraries; the WebView2 loader is linked statically and its bootstrapper downloaded.
3. In SignPath: project `agterm-win`, signing policy `release-signing`, artifact configuration `installer`
   (the one in the workflow's comment), GitHub as the trusted build system.
4. In this repository: secret `SIGNPATH_API_TOKEN`, variable `SIGNPATH_ORGANIZATION_ID`. MFA on GitHub and SignPath
   for every member.
