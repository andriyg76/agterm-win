# agterm-win versioning and release branches

agterm-win stops borrowing the upstream release number (`v0.44.1.11`) and gets its own semver,
while every release stays locked to exactly one upstream agterm release.

## Version number

- `agterm-windows/AGTERM_VERSION` stays the upstream pin (`0.44.1`): agterm-server download, checksums, `--install-server`.
- New `agterm-windows/VERSION` holds the release line `major.minor` (`1.0`); the patch is the next free `v<line>.<n>` tag.
- Minor bumps whenever `AGTERM_VERSION` moves to another upstream release; patch is a Windows-only release on the same pin;
  major is a deliberate break (state/settings format, Store debut).
  One line maps to one upstream version: `1.0.x` → agterm `0.44.1`, `1.1.x` → the next pin.
- First release under the scheme is `1.0.0`: it must sort above `0.44.1.11` (MSIX `0.44.1011.0`) for winget, Chocolatey,
  Inno and MSIX upgrades.
- User-facing name: `agterm-win 1.0.3 (agterm 0.44.1)` in the release title, Inno `AppVerName` and About.
- MSIX maps `a.b.c` to `a.b.c.0` directly; the `1000*c+n` encoding and its `c < 65`, `n < 1000` limits go.

## Release branches

A release runs only from `windows-port` or a `version/v<major>.<minor>` branch; anything else fails in the `version` job
(and in `release.ps1` for local runs).

- `windows-port` releases its current `VERSION` line.
- `version/v<line>` is a maintenance branch for a line already superseded on `windows-port`.
  Its `VERSION` must equal the branch suffix, so `version/v1.0` can only tag `v1.0.*`.
- A line releases from exactly one branch: `windows-port` refuses its `VERSION` line once `version/v<line>` exists.
- Cutting a line: when `windows-port` moves `AGTERM_VERSION`, branch `version/v<old line>` from the last release tag of
  that line (only if maintenance is wanted) and bump `VERSION` on `windows-port` in the same change.
- A maintenance release is not the newest line, so it publishes with `gh release create --latest=false`.
  winget and Chocolatey accept it as an extra version (upgrades still pick the highest); the Store gets only the newest line.
- Release notes take the previous tag reachable from the released commit (`git describe --tags --abbrev=0 HEAD^`),
  which is right on both branch kinds and across the switch from the 4-part tags.

## Changes

- `.github/workflows/windows-release.yml`: branch guard, next version from `VERSION` + `v<line>.*` tags, `--latest=false`
  for a line below the highest released one; drop the `windows-port`-only `if`.
- `scripts/release.ps1`, `stage.ps1`, `package-ci.ps1`: validate `^\d+\.\d+\.\d+$` against `VERSION`, not `AGTERM_VERSION`.
- `scripts/msix.ps1`: direct `a.b.c.0`.
- `scripts/release-notes.ps1`: previous tag via `git describe`.
- `stage.ps1` `build-info.json` gains `agtermVersion`; `main.swift` About shows both; `agterm.iss` `AppVerName`.
- `packaging/README.md`, `CLAUDE.md`/rules where the `v<AGTERM_VERSION>.<n>` scheme is stated.
- Unchanged: `fetch-server.ps1`, `ServerCommandsWindows.swift` (read only `AGTERM_VERSION`).

## Progress

- [ ] scheme and branch rule agreed
- [ ] workflow + scripts
- [ ] About / installer naming
- [ ] docs
- [ ] first release `v1.0.0` from `windows-port`
