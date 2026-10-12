#!/usr/bin/env bash
# Opens an issue for a failed run, or comments on the open one for the same upstream release.
#
# Usage: report-failure.sh [<upstream tag>]
# Env:   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID
set -euo pipefail

main() {
    local title="sidescreen-release failed for ${1:-the latest upstream release}"
    local run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    local existing
    existing="$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --search "$title in:title" --json number --jq '.[0].number')"
    if test -n "$existing"; then
        gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" --body "Failed again: $run_url"
    else
        gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" \
            --body "Nothing was released. The rebase conflicted, or building, testing or notarizing failed: $run_url"
    fi
}

main "$@"
