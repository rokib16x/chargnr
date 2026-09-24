#!/bin/bash
# Copies Developer ID signing and notarization credentials into this repo's
# GitHub Actions secrets, so the Release workflow can sign and notarize.
#
#   ./scripts/set-release-secrets.sh /path/to/Signing/private
#
# The folder must contain application.p12, p12.password and notary.p8 (the same
# files listnr's Signing/setup-signing.sh produces). Nothing is written to disk
# and nothing leaves your Mac except the secrets sent to GitHub over gh.
set -euo pipefail

REPO="rokib16x/chargnr"
DIR="${1:-}"
[[ -d "$DIR" ]] || { echo "usage: $0 /path/to/Signing/private" >&2; exit 1; }
for f in application.p12 p12.password notary.p8; do
  [[ -f "$DIR/$f" ]] || { echo "missing $DIR/$f" >&2; exit 1; }
done
command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }

read -r -p "Notary Key ID (10 characters, from the AuthKey_XXXXXXXXXX.p8 name): " key_id
read -r -p "Notary Issuer ID (UUID from App Store Connect → Users and Access → Integrations): " issuer_id
[[ -n "$key_id" && -n "$issuer_id" ]] || { echo "both IDs are required" >&2; exit 1; }

set_secret() { gh secret set "$1" --repo "$REPO" --body "$2" && echo "  set $1"; }
set_secret MACOS_APP_CERT_P12      "$(base64 < "$DIR/application.p12")"
set_secret MACOS_CERT_PASSWORD     "$(cat "$DIR/p12.password")"
set_secret MACOS_KEYCHAIN_PASSWORD "$(/usr/bin/openssl rand -base64 24)"
set_secret NOTARY_KEY_P8           "$(base64 < "$DIR/notary.p8")"
set_secret NOTARY_KEY_ID           "$key_id"
set_secret NOTARY_ISSUER_ID        "$issuer_id"

echo
echo "Done. Rehearse with a dry run (builds, signs, notarizes, publishes nothing):"
echo "  gh workflow run release.yml -R $REPO -f tag=v0.2.0"
