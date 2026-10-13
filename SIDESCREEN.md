# AeroSpace, `sidescreen` branch

This branch is upstream [AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko plus two patches.
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
[PR #2306](https://github.com/nikitabobko/AeroSpace/pull/2306). If upstream merges it, the branch keeps only the closet patch.

## The closet

Upstream AeroSpace hides the windows of invisible workspaces off screen, in a bottom corner of a monitor, with a pixel
left showing. Apps pull such windows back onto a screen whenever a display is added or removed, so every display change
flashes them on your monitor until AeroSpace hides them again, 0.15 to 2 s later. Apps that make virtual displays add
and remove displays often.

This branch moves those windows to a virtual display of its own instead, the closet, and drops the corner logic:

- Nothing of hidden windows shows on your monitors, and display changes don't move them: on a MacBook with an external
  monitor, a virtual display added and removed moved 5 hidden windows 20 times with corner hiding, and none over 3
  changes with the closet.
- Monitors can be arranged in any way. Upstream needs free space in a bottom corner of each.
- The closet sits diagonally off the bottom-right corner of the monitors. AeroSpace moves the pointer back if it gets
  there. It isn't a monitor for AeroSpace: no workspace, not in `list-monitors`.
- If AeroSpace crashes, macOS moves the windows on the closet to the remaining monitors.
- The closet shows in System Settings > Displays as "AeroSpace Closet". The virtual display API has no option to hide
  it there. If the closet becomes the main display, AeroSpace stops hiding windows until another display is main.

The closet is made with the private `CGVirtualDisplay` API. It is kept in this fork only, not proposed upstream.

## How releases work

- The branch is the latest upstream release tag plus three commits: the `ignored-monitors` patch, the fork files
  (this file, the README note, `.github/workflows/sidescreen-release.yml` and the scripts in `.github/sidescreen/`),
  and the closet patch. No upstream file other than README.md is changed outside the patches.
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
