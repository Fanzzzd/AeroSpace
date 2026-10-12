#!/usr/bin/env bash
# Signs AeroSpace.app and bin/aerospace of a release directory for distribution, notarizes them and staples the app.
#
# build-release.sh signs without the hardened runtime and a secure timestamp, and leaves get-task-allow in the app.
# Notarization rejects all three, so both binaries are signed again with the entitlements of the repository.
#
# Usage: notarize.sh .release/AeroSpace-v<version>
# Env:   CODESIGN_IDENTITY, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID,
#        and either APPLE_API_KEY_PATH (a .p8 file) or APPLE_API_KEY_P8_BASE64
set -euo pipefail

main() {
    local dir="$1"
    local app="$dir/AeroSpace.app" cli="$dir/bin/aerospace"
    local entitlements
    entitlements="$(cd "$(dirname "$0")/../.." && pwd)/resources/AeroSpace.entitlements"

    codesign --force --options runtime --timestamp -s "$CODESIGN_IDENTITY" "$cli"
    codesign --force --options runtime --timestamp --entitlements "$entitlements" -s "$CODESIGN_IDENTITY" "$app"
    codesign --verify --strict --deep "$app"

    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064 # Expand now: $tmp is local and is gone when the trap runs
    trap "rm -rf '$tmp'" EXIT
    local key="${APPLE_API_KEY_PATH:-$tmp/api-key.p8}"
    if test -z "${APPLE_API_KEY_PATH:-}"; then echo "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$key"; fi
    local auth=(--key "$key" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")

    ditto -c -k --keepParent "$dir" "$tmp/submission.zip"
    local result id status
    result="$(xcrun notarytool submit "$tmp/submission.zip" --wait --timeout 30m --output-format json "${auth[@]}")"
    id="$(jq -r .id <<< "$result")"
    status="$(jq -r .status <<< "$result")"
    echo "Notarization $id: $status"
    # notarytool exits with 0 for Invalid and Rejected submissions too
    if test "$status" != Accepted; then
        xcrun notarytool log "$id" "${auth[@]}"
        exit 1
    fi

    # The command line tool can't be stapled. Gatekeeper looks its ticket up online
    xcrun stapler staple "$app"
    spctl --assess --type execute -vv "$app"
}

main "$@"
