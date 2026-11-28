# agterm-win packaging

Running `.github/workflows/windows-release.yml` (Actions ▸ windows-release ▸ Run workflow, or
`gh workflow run windows-release.yml --ref windows-port -f kind=incremental`) tags the next version, builds the x64 and
arm64 installers natively on `windows-2022` and `windows-11-arm` with `scripts\release.ps1`, has SignPath sign them once
`SIGNPATH_ORGANIZATION_ID` is set (releases ship unsigned until then), and publishes the release. `scripts\release.ps1 -Version <version> [-Arch x64|arm64] [-Publish]` does the same locally for the
host's architecture; its header lists the tools and the signing variables.

**Versions** are `<major>.<minor>.<patch>`: `major.minor` is the pinned upstream's (`AGTERM_VERSION`), `patch` counts
agterm-win releases on that line, so `0.44.2` is built on agterm `0.44.1` and the two patches are unrelated.
The release title and About show both, as `agterm-win 0.44.2 (agterm 0.44.1)`. The workflow's `kind` picks the next one
(`scripts\release-version.ps1` enforces it):

| `kind` | Branch | Next | When |
|---|---|---|---|
| `incremental` | `windows-port` | `0.44.2` → `0.44.3` | any release on the same upstream minor, an upstream patch bump included |
| `master` | `windows-port` | `0.45.0` | `AGTERM_VERSION` moved to a new upstream minor; also creates `version/v0.44` at the last `0.44` tag |
| `hotfix` | `version/v0.44` | `0.44.7` → `0.44.8` | a fix for a line `windows-port` has left; published without GitHub's Latest |

Any other branch or kind/branch pairing fails before the build, and `windows-port` refuses a line once its
`version/v*` branch exists. MSIX takes the version with a `.0` fourth part, as the Store requires.

- **GitHub**: `-Publish` uploads the installer, the portable zip and their `.sha256` files to this fork's release
  `v<version>`, creating it for the first architecture and adding to it for the second.
- **Portable zip**: `agterm-win-<version>-<arch>-portable.zip` is the stage `release.ps1` signs, unpacked into any
  folder and started with `agterm-win.exe`; it skips the installer's Start menu entry and PATH change, so add the folder
  to PATH for `agtermctl`. `windows-release.yml` zips it before SignPath, which signs only the installer, so the
  release's zips are unsigned.
- **winget / Chocolatey**: `scripts\package-managers.ps1 -Version <version>` renders `winget/` and `chocolatey/` for
  that release's two installers into `build\package-managers\<version>`. The winget folder goes to a `microsoft/winget-pkgs` PR as
  `manifests/a/andriyg76/agterm-win/<version>`; the `.nupkg` is pushed with `choco push` and the account's API key.
  Both identifiers are `agterm-win`, leaving `agterm` to upstream.
- **CI (`windows.yml`)**: after tests, `scripts\package-ci.ps1` builds an unsigned Inno installer, a portable zip and a
  Store MSIX (plus a registerable layout) and uploads `ci-installer-*`, `ci-portable-*`, `ci-msix-*`, and
  `msix-store-layout-*` on every run.
- **Microsoft Store**: one MSIX per architecture from `scripts\msix.ps1`, which `windows-release.yml` uploads as the
  `msix-x64` and `msix-arm64` artifacts; both go into the same Partner Center submission, and the Store signs them. Its identity comes from the repository variables `MSIX_IDENTITY_NAME`,
  `MSIX_PUBLISHER` and `MSIX_PUBLISHER_DISPLAY_NAME`, as Partner Center's Product identity page shows them.
  Store submission notes: `packaging/msix/STORE-SUBMISSION.md`. MSIX smoke test: `packaging/msix/TESTING-VIRTUALIZED.md`
  and sideload `packaging/msix/sideload/*.bat` (copied into each layout by `msix.ps1`). Production manifest uses
  default Store virtualization (no `unvirtualizedResources`); `msix.ps1 -Unvirtualized` is local/winget parity only.
  The package needs Windows 10 1903, puts `agtermctl` on PATH as its one execution alias; `agterm-win` starts from the Start menu.
  A Store update ends the package's processes, local zmx sessions included; WSL sessions live in the distribution.

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
the user or the person installing or operating it. `--install-server` downloads agterm-server from GitHub only when run. The full policy,
for the Store listing's privacy policy URL, is [PRIVACY.md](../PRIVACY.md).

### Setting SignPath up

1. Publish one unsigned release first (run the workflow with no SignPath variables set): SignPath signs only projects
   already released in the form to be signed. Link this section from the repository's home page and its releases.
2. Apply at https://signpath.org/apply. Ask there whether the Swift runtime and MSVC runtime DLLs the installer
   carries count as system libraries.
3. In SignPath: project `agterm-win`, signing policy `release-signing`, artifact configuration `installer`
   (the one in the workflow's comment), GitHub as the trusted build system.
4. In this repository: secret `SIGNPATH_API_TOKEN`, variable `SIGNPATH_ORGANIZATION_ID`. MFA on GitHub and SignPath
   for every member.

**Release notes (`scripts/release-notes.ps1`):** the publish step lists commits and merged PRs on the released branch since the previous release tag reachable from it. Optional secret **`OPENAI_API_KEY`** and variable **`OPENAI_MODEL`** (default `GPT-6.1-terra`) ask the API to group features vs refactors; without the key, notes list PRs and commits directly.
