# agterm-win versioning and release branches

agterm-win stops borrowing the upstream release number (`v0.44.1.11`) and gets its own semver,
while every release stays locked to exactly one upstream agterm release.

## Version number

- `agterm-windows/AGTERM_VERSION` stays the upstream pin (`0.44.1`): agterm-server download, checksums, `--install-server`.
- agterm-win is `major.minor.patch`: `major.minor` is the pinned upstream's (a line), `patch` is agterm-win's own counter.
  `0.44.x` is built on some agterm `0.44.y`; the two patch numbers are unrelated.
- The next release is `0.44.1012`: a 4-part tag counts as its MSIX version (`v0.44.1.11` → `0.44.1011`), which is in the Store,
  so no channel sees a downgrade. Lines from `0.45` start at `.0`.
- User-facing name: `agterm-win 0.44.1012 (agterm 0.44.1)` in the release title, Inno `AppVerName` and About.
- MSIX: `a.b.c` → `a.b.c.0`.

## Release kind (workflow input `kind`)

The base is the newest release tag reachable from the dispatched commit (`git describe --tags --abbrev=0 --match 'v*'`);
a 4-part base tag counts as its MSIX version (`v0.44.1.11` → `0.44.1011`).

| `kind` | Branch | Next version | Guard |
|---|---|---|---|
| `master` | `windows-port` | `<pin major>.<pin minor>.0` | pin's `major.minor` differs from the base line |
| `incremental` | `windows-port` | `major.minor.(patch+1)` | pin's `major.minor` equals the base line, else use `master` |
| `hotfix` | `version/v<major>.<minor>` | `major.minor.(patch+1)` | base tag and pin are in the branch's line |

- Any other branch, or a kind on the wrong branch, fails in the `version` job; `release.ps1` applies the same check locally.
- For now the minor moves only with upstream's minor; decoupling it later means relaxing only the `master` guard.
- An upstream patch bump inside a line (`AGTERM_VERSION` 0.44.1 → 0.44.3) is an `incremental` release.
- `master` also pushes `version/v<previous line>` at the previous line's last tag when that branch does not exist yet,
  so a hotfix for the superseded line always has its branch.
- `hotfix` publishes with `gh release create --latest=false` ; winget and Chocolatey accept it as an
  extra version, and upgrades still pick the highest.
- Release notes cover the base tag to the released commit, which is right for all three kinds and across the switch
  from the 4-part tags.

## Changes

- `.github/workflows/windows-release.yml`: `kind` choice input, branch/kind/pin guard, next version from the base tag,
  `version/v*` creation on `master`, `--latest=false` on `hotfix`; drop the `windows-port`-only `if`.
- `scripts/release.ps1`, `stage.ps1`, `package-ci.ps1`: validate `^\d+\.\d+\.\d+$` with `major.minor` equal to `AGTERM_VERSION`'s.
- `scripts/msix.ps1`: `a.b.c` package version .
- `scripts/release-notes.ps1`: base tag via `git describe`.
- `stage.ps1` `build-info.json` gains `agtermVersion`; `main.swift` About shows both; `agterm.iss` `AppVerName`.
- `packaging/README.md`, `CLAUDE.md`/rules where the `v<AGTERM_VERSION>.<n>` scheme is stated.
- Unchanged: `fetch-server.ps1`, `ServerCommandsWindows.swift` (read only `AGTERM_VERSION`).

## Progress

- [x] scheme, branch rule and kinds agreed
- [x] workflow + scripts
- [x] About / installer naming
- [x] docs
- [ ] first release `v0.44.1012` from `windows-port` (`kind: incremental`)
