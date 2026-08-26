#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

# Builds a distributable Constellation.app: Release archive signed with
# Developer ID and the Hardened Runtime, notarized, stapled, and zipped.
#
#   Scripts/release.sh <version> [build-number]
#
# Environment:
#   NOTARY_PROFILE  notarytool keychain profile (default: constellation-notary).
#                   Create one with:
#                     xcrun notarytool store-credentials constellation-notary \
#                       --apple-id <apple-id> --team-id 45QKSLQ5S4
#                   (it asks for an app-specific password and keeps it in Keychain).
#   NOTARY_KEY_FILE, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                   App Store Connect API key; when all three are set they are
#                   used instead of the keychain profile (CI has no profile).
#   SKIP_NOTARIZE=1 stop after signing; useful to inspect the bundle offline.
#
# Output lands in build/release/<version>/. Nothing is uploaded except the
# notarization submission to Apple.
set -euo pipefail

VERSION="${1:?usage: release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-$(git rev-list --count HEAD)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-constellation-notary}"
if [[ -n "${NOTARY_KEY_FILE:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  NOTARY_AUTH_DESCRIPTION="API key $NOTARY_KEY_ID"
else
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  NOTARY_AUTH_DESCRIPTION="profile $NOTARY_PROFILE"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/release/$VERSION"
ARCHIVE="$OUT/Constellation.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Constellation.app"
ZIP="$OUT/Constellation-$VERSION.zip"

cd "$ROOT"
if [[ ! -d Constellation.xcodeproj ]]; then
  xcodegen generate
fi
for kit in Packages/ConstellationTerminal/GhosttyKit.xcframework Packages/ConstellationRemoteDesktop/FreeRDPKit.xcframework; do
  if [[ ! -e "$kit/Info.plist" ]]; then
    echo "$kit is missing; run Scripts/build-libghostty.sh and Scripts/build-freerdp.sh" >&2
    exit 1
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Archiving $VERSION ($BUILD_NUMBER)..."
xcodebuild archive \
  -project Constellation.xcodeproj \
  -scheme Constellation \
  -onlyUsePackageVersionsFromResolvedFile \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  ARCHS=arm64 \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

# Export re-signs the app and everything nested in it (the askpass helper
# included) with the Developer ID identity and a secure timestamp.
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>45QKSLQ5S4</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "Exporting..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  -quiet

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|CodeDirectory)' | sed 's/^/  /'
codesign --display --verbose=2 "$APP/Contents/MacOS/constellation-askpass" 2>&1 | grep -E '^(Identifier|CodeDirectory)' | sed 's/^/  helper: /'
for binary in "$APP/Contents/MacOS/Constellation" "$APP/Contents/MacOS/constellation-askpass"; do
  signature="$(codesign --display --verbose=2 "$binary" 2>&1)"
  if [[ "$signature" != *"flags="*"(runtime)"* ]]; then
    echo "$binary is not signed with the Hardened Runtime" >&2
    exit 1
  fi
done

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "SKIP_NOTARIZE set; signed app at $APP"
  exit 0
fi

echo "Notarizing ($NOTARY_AUTH_DESCRIPTION)..."
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
submission="$(xcrun notarytool submit "$OUT/notarize.zip" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
echo "$submission"
rm -f "$OUT/notarize.zip"
if [[ "$submission" != *"status: Accepted"* ]]; then
  echo "Notarization was not accepted; fetching the log..." >&2
  submission_id="$(sed -n 's/^ *id: //p' <<<"$submission" | head -1)"
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" "${NOTARY_AUTH[@]}" >&2
  fi
  exit 1
fi

echo "Stapling..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$ZIP.sha256")
echo "Release ready: $ZIP"
cat "$ZIP.sha256"
