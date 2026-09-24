#!/bin/bash
# Signs chargnr.app inside out with hardened runtime and a secure timestamp.
#
#   app=path/to/chargnr.app scripts/sign-app.sh "Developer ID Application"
#   app=path/to/chargnr.app scripts/sign-app.sh -        # ad hoc, to check locally
#
# The helper and CLI get explicit identifiers: a team-signed helper only
# accepts XPC callers signed as com.rokib16x.chargnr or com.rokib16x.chargnr.cli.
set -euo pipefail

identity="${1:?usage: app=chargnr.app $0 IDENTITY}"
app="${app:?set app=path/to/chargnr.app}"
macos="$app/Contents/MacOS"
timestamp=(--timestamp)
[[ "$identity" == "-" ]] && timestamp=(--timestamp=none)

sign() { codesign --force --sign "$identity" --options runtime "${timestamp[@]}" "$@"; }

sign --identifier com.rokib16x.chargnr.helper "$macos/chargnr-helper"
sign --identifier com.rokib16x.chargnr.cli "$macos/chargnr-cli"
sign "$app"

codesign --verify --strict --deep --verbose=2 "$app"
for binary in "$macos/chargnr-helper" "$macos/chargnr-cli" "$app"; do
  codesign --display --verbose=2 "$binary" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Runtime Version|flags)" | sed "s|^|  $(basename "$binary"): |"
done
