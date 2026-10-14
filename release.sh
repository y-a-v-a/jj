#!/usr/bin/env bash
# Builds a universal JJ.app signed with a Developer ID, has Apple notarize it,
# staples the ticket and packages dist/JJ.zip.
#
#   ./release.sh              signed, notarized and stapled dist/JJ.zip
#   ./release.sh --publish    also create the GitHub release v<version> with the zip
#   ./release.sh --sign-only  signed with the hardened runtime, not notarized
#                             (with --publish: a release that says so)
#
# Notarizing needs a notarytool keychain profile for the signing team. To
# create one (with an app-specific password from https://account.apple.com):
#
#   xcrun notarytool store-credentials mould-notary \
#     --apple-id you@example.com --team-id HFFHH9CJYF
#
# NOTARY_PROFILE names the profile (default: mould-notary), SIGN_IDENTITY the
# certificate (default: the first "Developer ID Application" identity) and
# JJ_VERSION the version (default: the latest v* tag, else 1.0.0).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PROFILE="${NOTARY_PROFILE:-mould-notary}"
PUBLISH=0
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --sign-only) NOTARIZE=0 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done
if [[ $PUBLISH == 1 && -n "$(git status --porcelain)" ]]; then
  echo "The working tree has uncommitted changes; commit them before publishing a release." >&2
  exit 1
fi

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
  echo "No \"Developer ID Application\" certificate in the keychain; set SIGN_IDENTITY." >&2
  exit 1
fi

# Fail before the slow build if the notary credentials aren't there (or the keychain is locked).
if [[ $NOTARIZE == 1 ]] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Can't use notary profile '$PROFILE'. Create it (see the top of this script), unlock the" >&2
  echo "login keychain, or set NOTARY_PROFILE to an existing profile." >&2
  exit 1
fi

./build.sh --universal

APP="$ROOT/dist/JJ.app"
ZIP="$ROOT/dist/JJ.zip"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"

echo "▸ Signing with $IDENTITY"
# The hardened runtime is required for notarization; JJ needs no exceptions to it.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# The notary service takes a zip; ditto keeps the bundle's metadata intact.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ $NOTARIZE == 1 ]]; then
  echo "▸ Notarizing (usually a few minutes)"
  RESULT="$(mktemp)"
  trap 'rm -f "$RESULT"' EXIT
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT"
  STATUS="$(plutil -extract status raw -o - "$RESULT")"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization ended as '$STATUS'. Apple's log:" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - "$RESULT")" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
  # Staple the ticket so Gatekeeper can check it offline, then zip the stapled app.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
  echo "✓ Notarized and stapled: $APP ($VERSION)"
else
  echo "✓ Signed, not notarized: $APP ($VERSION)"
fi
echo "  $ZIP"

if [[ $PUBLISH == 1 ]]; then
  NOTES="Download \`JJ.zip\`, unzip it and move \`JJ.app\` to /Applications. One app for Apple silicon and Intel Macs, macOS 15 or later."
  if [[ $NOTARIZE == 1 ]]; then
    NOTES+=" Signed with a Developer ID and notarized by Apple."
  else
    NOTES+=$'\n\n'"Signed with a Developer ID but not notarized, so macOS stops it the first time: open it once, then choose *Open Anyway* under System Settings → Privacy & Security. Or clear the quarantine flag: \`xattr -dr com.apple.quarantine /Applications/JJ.app\`."
  fi
  gh release create "v$VERSION" "$ZIP" --target "$(git rev-parse HEAD)" --title "JJ $VERSION" \
    --notes "$NOTES" --generate-notes
fi
