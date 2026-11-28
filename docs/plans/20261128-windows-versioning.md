# agterm-win versioning and release branches

agterm-win stops borrowing the upstream release number (`v0.44.1.11`) and gets its own semver.

## Version number

- agterm-win is its own `major.minor.patch`, with no tie to upstream's numbers.
- `agterm-windows/AGTERM_VERSION` stays only the upstream pin (`0.44.1`): agterm-server download, checksums,
  `--install-server`, and the `(agterm 0.44.1)` shown beside the version.
- The next release is `0.44.1012`: a 4-part tag counts as its MSIX version (`v0.44.1.11` → `0.44.1011`), which is in the
  Store, so no channel sees a downgrade.
- User-facing name: `agterm-win 0.44.1012 (agterm 0.44.1)` in the release title, Inno `AppVerName` and About.
- MSIX: `a.b.c` → `a.b.c.0`.
- `agterm-windows/VERSION` holds the line as `major.minor.0` (`0.44.0`) for every unreleased build.
  `incremental` leaves it; `minor`/`major` commit the new `.0` to the branch in the `version` job and build that commit,
  so the tag and every later unreleased build carry the new line.

## Upstream sync

Moving to a new upstream release is its own change, never part of a release: merge the upstream tag into
`windows-port` and bump `AGTERM_VERSION` in the same PR (as `0f4a085` did for 0.44.1). It changes no agterm-win
version; the next release picks the kind its changes deserve.

## Release kind (workflow input `kind`)

The base is the newest release tag reachable from the dispatched commit (`git describe --tags --abbrev=0 --match 'v*'`).

| `kind` | Branch | Next version |
|---|---|---|
| `incremental` | `windows-port` or `version/v<major>.<minor>` | `major.minor.(patch+1)` |
| `minor` | `windows-port` | `major.(minor+1).0` |
| `major` | `windows-port` | `(major+1).0.0` |

- A release runs only from `windows-port` or `version/v<major>.<minor>`; any other branch fails in the `version` job,
  and `release.ps1 -Publish` applies the same check locally.
- `version/v<line>` takes only `incremental`, its base tag must be in that line, and it publishes with
  `gh release create --latest=false`; winget and Chocolatey accept it as an extra version, and upgrades still pick
  the highest.
- `minor` and `major` push `version/v<previous line>` at the previous line's last tag when that branch does not exist yet.
- `windows-port` refuses `incremental` for a line once its `version/v*` branch exists.
- Release notes cover the base tag to the released commit.

## Progress

- [x] scheme, branch rule and kinds agreed
- [x] workflow + scripts
- [x] About / installer naming
- [x] docs
- [ ] first release `v0.44.1012` from `windows-port` (`kind: incremental`)
