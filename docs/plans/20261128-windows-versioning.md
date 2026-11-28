# agterm-win versioning and release branches

agterm-win stops borrowing the upstream release number (`v0.44.1.11`) and gets its own semver,
while every release stays locked to exactly one upstream agterm release.

## Version number

- `agterm-windows/AGTERM_VERSION` stays the upstream pin (`0.44.1`): agterm-server download, checksums, `--install-server`.
- agterm-win is `major.minor.patch`; a line is `major.minor` and maps to one upstream pin: `1.0.x` → agterm `0.44.1`.
  The line's pin is read from the line's tags (`git show v1.0.0:agterm-windows/AGTERM_VERSION`), so no extra version
  file and no bot commits.
- First release under the scheme is `1.0.0`: it must sort above `0.44.1.11` (MSIX `0.44.1011.0`) for winget, Chocolatey,
  Inno and MSIX upgrades.
- User-facing name: `agterm-win 1.0.3 (agterm 0.44.1)` in the release title, Inno `AppVerName` and About.
- MSIX maps `a.b.c` to `a.b.c.0` directly; the `1000*c+n` encoding and its `c < 65`, `n < 1000` limits go.

## Release kind (workflow input `kind`)

The base is the newest release tag reachable from the dispatched commit (`git describe --tags --abbrev=0 --match 'v*'`).

| `kind` | Branch | Next version | Guard |
|---|---|---|---|
| `master` | `windows-port` | `major.(minor+1).0`; from a 4-part tag, `1.0.0` | — |
| `incremental` | `windows-port` | `major.minor.(patch+1)` | `AGTERM_VERSION` equals the line's pin, else use `master` |
| `hotfix` | `version/v<major>.<minor>` | `major.minor.(patch+1)` | base tag is in the branch's line; pin unchanged |

- Any other branch, or a kind on the wrong branch, fails in the `version` job; `release.ps1` applies the same check locally.
- `master` also pushes `version/v<previous line>` at the previous line's last tag when that branch does not exist yet,
  so a hotfix for the superseded line always has its branch.
- A major bump is a deliberate break (state/settings format, Store debut) and is left to a later `major` kind or a manual tag.
- `hotfix` publishes with `gh release create --latest=false` and skips the Store; winget and Chocolatey accept it as an
  extra version, and upgrades still pick the highest.
- Release notes cover the base tag to the released commit, which is right for all three kinds and across the switch
  from the 4-part tags.

## Changes

- `.github/workflows/windows-release.yml`: `kind` choice input, branch/kind/pin guard, next version from the base tag,
  `version/v*` creation on `master`, `--latest=false` on `hotfix`; drop the `windows-port`-only `if`.
- `scripts/release.ps1`, `stage.ps1`, `package-ci.ps1`: validate `^\d+\.\d+\.\d+$`, not the `AGTERM_VERSION` prefix.
- `scripts/msix.ps1`: direct `a.b.c.0`.
- `scripts/release-notes.ps1`: base tag via `git describe`.
- `stage.ps1` `build-info.json` gains `agtermVersion`; `main.swift` About shows both; `agterm.iss` `AppVerName`.
- `packaging/README.md`, `CLAUDE.md`/rules where the `v<AGTERM_VERSION>.<n>` scheme is stated.
- Unchanged: `fetch-server.ps1`, `ServerCommandsWindows.swift` (read only `AGTERM_VERSION`).

## Progress

- [ ] scheme, branch rule and kinds agreed
- [ ] workflow + scripts
- [ ] About / installer naming
- [ ] docs
- [ ] first release `v1.0.0` from `windows-port`
