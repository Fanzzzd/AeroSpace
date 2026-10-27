#!/usr/bin/env bash
# Imports the Developer ID certificate into a temporary keychain on GitHub Actions, or deletes that keychain.
#
# Usage: keychain.sh import   (needs DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD and CODESIGN_IDENTITY)
#        keychain.sh delete
set -euo pipefail

keychain="$RUNNER_TEMP/signing.keychain-db"

import() {
    local password p12="$RUNNER_TEMP/developer-id.p12"
    password="$(uuidgen)"
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$password" "$keychain"

    echo "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$p12"
    security import "$p12" -P "$DEVELOPER_ID_P12_PASSWORD" -f pkcs12 -k "$keychain" -T /usr/bin/codesign
    rm "$p12"
    security set-key-partition-list -S apple-tool:,apple: -k "$password" "$keychain" > /dev/null

    local keychains=()
    while IFS= read -r line; do keychains+=("$(echo "$line" | xargs)"); done < <(security list-keychains -d user)
    security list-keychains -d user -s "$keychain" "${keychains[@]}"
    security find-identity -v -p codesigning "$keychain" | grep -F "$CODESIGN_IDENTITY"
}

delete() {
    security delete-keychain "$keychain" 2> /dev/null || true
}

case "${1:-}" in
    import) import ;;
    delete) delete ;;
    *) echo "Usage: $0 import|delete" > /dev/stderr; exit 1 ;;
esac
