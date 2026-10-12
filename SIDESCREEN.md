# AeroSpace, `sidescreen` branch

This branch is upstream [AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko plus one patch.
All credit for AeroSpace goes to its authors. The license is unchanged (MIT, see [legal/LICENSE.txt](./legal/LICENSE.txt)).

## What it adds

```toml
# AeroSpace doesn't manage monitors whose name matches one of these case insensitive regexes
ignored-monitors = ['^Sidescreen']
```

Some apps create virtual displays for AI agents. Stock AeroSpace treats them as regular monitors: it shows one of your
workspaces there, shifts monitor sequence numbers, and tiles and hides the windows the agent opens. With
`ignored-monitors`:

- AeroSpace doesn't show workspaces on matching monitors. They don't count in monitor sequence numbers, `main`,
  `secondary`, `list-monitors` or `focus-monitor`.
- AeroSpace doesn't lay out, hide or move windows whose center is on a matching monitor. When such a window is moved
  back to a managed monitor, AeroSpace lays it out on that monitor's visible workspace.
- The main monitor is never ignored. Only name regexes are accepted.

The option is proposed upstream in [Discussion #2305](https://github.com/nikitabobko/AeroSpace/discussions/2305) and
[PR #2306](https://github.com/nikitabobko/AeroSpace/pull/2306). If upstream merges it, this branch will be retired.

## How releases work

- The branch is the latest upstream release tag plus two commits: the `ignored-monitors` patch, and the fork files
  (this file, the README note, `.github/workflows/sidescreen-release.yml` and the scripts in `.github/sidescreen/`).
  No upstream file other than README.md is changed outside the patch.
- Once a week, GitHub Actions rebases those commits onto the latest upstream release, builds, and runs upstream's
  `./test.sh`. When upstream has published a release that this fork hasn't, it builds it with `./build-release.sh`,
  notarizes it, and publishes `sidescreen-<upstream tag>` on the Releases page of this repository.
- If the rebase conflicts, or building, testing or notarizing fails, it opens an issue instead of releasing.
- Release builds are signed with a Developer ID (team 59AW6PWR73) with the hardened runtime, notarized by Apple, and
  stapled.
- The scripts run locally too. For example, to build a notarized zip without publishing it:
  `.github/sidescreen/release.sh v0.21.3-Beta --no-publish` with `CODESIGN_IDENTITY`, `APPLE_API_KEY_ID`,
  `APPLE_API_ISSUER_ID` and `APPLE_API_KEY_PATH` set.
- The app keeps the bundle id `bobko.aerospace` and the name `AeroSpace.app`, so it replaces stock AeroSpace and reads
  the same config. macOS asks for the Accessibility permission again after switching, because the signature differs.
