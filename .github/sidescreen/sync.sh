#!/usr/bin/env bash
# Rebases the commits of the sidescreen branch onto the latest upstream release.
# Prints `latest=<tag>`, `rebased=<bool>` and `released=<bool>`, and writes them to $GITHUB_OUTPUT on GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/../.."

output() {
    echo "$1=$2"
    if test -n "${GITHUB_OUTPUT:-}"; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

main() {
    git remote get-url upstream &> /dev/null || git remote add upstream https://github.com/nikitabobko/AeroSpace.git
    git fetch --quiet --tags upstream

    # Upstream marks every release as a prerelease, so releases/latest doesn't work
    local latest base
    latest="$(gh release list --repo nikitabobko/AeroSpace --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')"
    base="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD)"
    output latest "$latest"

    if test "$base" = "$latest"; then
        output rebased false
    else
        echo "Rebasing $(git rev-list --count "$base..HEAD") commits from $base onto $latest"
        git rebase --onto "$latest" "$base" HEAD
        output rebased true
    fi

    if gh release view "sidescreen-$latest" --repo "${GITHUB_REPOSITORY:-Fanzzzd/AeroSpace}" &> /dev/null; then
        output released true
    else
        output released false
    fi
}

main "$@"
