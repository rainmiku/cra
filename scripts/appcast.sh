#!/bin/bash
# Writes build/dist/appcast.xml, the Sparkle feed for the zip in build/dist, signed
# with the EdDSA private key (base64, as exported by Sparkle's generate_keys -x).
#   SPARKLE_PRIVATE_KEY=… CRA_DOWNLOAD_BASE=https://github.com/<owner>/cra/releases/download/v0.1.1 \
#     scripts/appcast.sh [path/to/Cra.app]
# Built apps read the feed from releases/latest/download/appcast.xml (see release.yml).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Cra.app}"
ZIP="build/dist/Cra.zip"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
: "${CRA_DOWNLOAD_BASE:?CRA_DOWNLOAD_BASE is required}"
[ -f "$ZIP" ] || { echo "No $ZIP. Run scripts/package.sh first." >&2; exit 1; }

PB=/usr/libexec/PlistBuddy
VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$($PB -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MIN_OS="$($PB -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

# sign_update ships with the Sparkle package SwiftPM resolved.
SIGN_UPDATE="$(find .build/artifacts -path '*/Sparkle/bin/sign_update' -type f | head -n 1)"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found; run swift package resolve." >&2; exit 1; }
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")"

cat > build/dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cra</title>
    <item>
      <title>Cra ${VERSION}</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <enclosure url="${CRA_DOWNLOAD_BASE}/Cra.zip" type="application/octet-stream" ${SIGNATURE} />
    </item>
  </channel>
</rss>
XML
echo "Wrote build/dist/appcast.xml for Cra ${VERSION} (${BUILD})"
