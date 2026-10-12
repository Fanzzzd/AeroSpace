#!/usr/bin/env bash
# Builds, notarizes and publishes `sidescreen-<upstream tag>`.
#
# Usage: release.sh <upstream tag> [--no-publish]
# Env:   everything notarize.sh needs, and GH_TOKEN unless --no-publish
set -euo pipefail
cd "$(dirname "$0")/../.."

main() {
    local tag="$1" publish=true
    if test "${2:-}" = --no-publish; then publish=false; fi
    local version="${tag#v}-sidescreen"
    local dir=".release/AeroSpace-v$version" zip=".release/AeroSpace-v$version.zip"

    ./build-release.sh --build-version "$version" --codesign-identity "$CODESIGN_IDENTITY"
    .github/sidescreen/notarize.sh "$dir"
    rm -f "$zip"
    ditto -c -k --keepParent "$dir" "$zip"

    local sha256
    sha256="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"
    echo "$zip $sha256"
    if ! $publish; then return; fi

    local repo="${GITHUB_REPOSITORY:-Fanzzzd/AeroSpace}"
    gh release create "sidescreen-$tag" "$zip" \
        --repo "$repo" \
        --target "$(git rev-parse HEAD)" \
        --title "AeroSpace $tag + ignored-monitors" \
        --prerelease \
        --notes-file - <<EOF
AeroSpace $tag by Nikita Bobko, plus the \`ignored-monitors\` option from the \`sidescreen\` branch of this fork.
See [SIDESCREEN.md](https://github.com/$repo/blob/sidescreen/SIDESCREEN.md) for what it adds and how it's built.
Upstream release notes: https://github.com/nikitabobko/AeroSpace/releases/tag/$tag

Signed with a Developer ID (team 59AW6PWR73) and notarized by Apple. The app keeps the bundle id \`bobko.aerospace\`,
so it replaces stock AeroSpace. macOS asks for the Accessibility permission again after switching.

SHA-256 of \`AeroSpace-v$version.zip\`: \`$sha256\`
EOF
}

main "$@"
