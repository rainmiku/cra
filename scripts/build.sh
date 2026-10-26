#!/bin/bash
# Builds Cra.app into build/Cra.app.
#   scripts/build.sh            release build, ad-hoc signed
#   scripts/build.sh debug      debug build
#   CRA_SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#                               distributable build (see docs/release.md)
#   CRA_SPARKLE_PUBLIC_KEY=… CRA_UPDATE_FEED_URL=https://…/appcast.xml scripts/build.sh
#                               build with Sparkle in-app updates turned on
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${1:-release}"
VERSION="${CRA_VERSION:-0.1.0}"
BUILD_NUMBER="${CRA_BUILD:-$(date +%Y%m%d%H%M)}"

scripts/fetch-cef.sh

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# Stage the bundle, then sync it into place so the existing Cra.app directory
# keeps its identity (LaunchServices otherwise launches duplicate instances).
FINAL_APP="$ROOT/build/Cra.app"
STAGE="$(mktemp -d /tmp/cra-stage.XXXXXX)"
APP="$STAGE/Cra.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/Cra" "$APP/Contents/MacOS/Cra"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" resources/Info.plist > "$APP/Contents/Info.plist"
if [ -n "${CRA_SPARKLE_PUBLIC_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $CRA_SPARKLE_PUBLIC_KEY" \
    -c "Add :SUFeedURL string ${CRA_UPDATE_FEED_URL:?CRA_UPDATE_FEED_URL is required with CRA_SPARKLE_PUBLIC_KEY}" \
    -c "Add :SUEnableAutomaticChecks bool true" -c "Add :SUAutomaticallyUpdate bool true" \
    -c "Add :SUScheduledCheckInterval integer 21600" "$APP/Contents/Info.plist"
fi
echo -n "APPL????" > "$APP/Contents/PkgInfo"
[ -f resources/AppIcon.icns ] && cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -d resources/web ] && cp -R resources/web "$APP/Contents/Resources/web"
[ -d resources/brand ] && cp -R resources/brand "$APP/Contents/Resources/brand"
[ -d resources/blocklist ] && cp -R resources/blocklist "$APP/Contents/Resources/blocklist"

FRAMEWORK_SRC="$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework"
cp -R "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/"
scripts/patch-cef-keychain.sh "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"

# CEF needs one helper app per process type (see cef_variables.cmake,
# CEF_HELPER_APP_SUFFIXES). Format: "<name suffix>|<plist suffix>".
for entry in "|" " (Alerts)|.alerts" " (GPU)|.gpu" " (Plugin)|.plugin" " (Renderer)|.renderer"; do
  NAME_SUFFIX="${entry%%|*}"
  PLIST_SUFFIX="${entry#*|}"
  HELPER="$APP/Contents/Frameworks/Cra Helper${NAME_SUFFIX}.app"
  mkdir -p "$HELPER/Contents/MacOS"
  cp "$BIN/CraHelper" "$HELPER/Contents/MacOS/Cra Helper${NAME_SUFFIX}"
  sed -e "s/__NAME_SUFFIX__/${NAME_SUFFIX}/g" -e "s/__PLIST_SUFFIX__/${PLIST_SUFFIX}/g" \
      -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
      resources/Helper-Info.plist > "$HELPER/Contents/Info.plist"
  echo -n "APPL????" > "$HELPER/Contents/PkgInfo"
done

# Code signing, innermost first. Ad-hoc by default; set CRA_SIGN_IDENTITY to a
# "Developer ID Application: …" identity for a distributable build with the
# hardened runtime, timestamps and the CEF entitlements. scripts/release.sh
# then notarizes the result.
IDENTITY="${CRA_SIGN_IDENTITY:--}"
sign() {  # sign <path> [entitlements]
  local target="$1" ent="${2:-}"
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$target"
  else
    local args=(--force --sign "$IDENTITY" --options runtime --timestamp)
    [ -n "$ent" ] && args+=(--entitlements "$ent")
    codesign "${args[@]}" "$target"
  fi
}
FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
find "$FW/Libraries" -name '*.dylib' -print0 2>/dev/null | while IFS= read -r -d '' lib; do sign "$lib"; done
sign "$FW"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  sign "$SPARKLE/Versions/B/$part"
done
sign "$SPARKLE"
for h in "$APP"/Contents/Frameworks/*.app; do sign "$h" "$ROOT/resources/CraHelper.entitlements"; done
sign "$APP" "$ROOT/resources/Cra.entitlements"
if [ "$IDENTITY" != "-" ]; then
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$FINAL_APP"
rsync -a --delete "$APP/" "$FINAL_APP/"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$STAGE"
"$LSREGISTER" -f "$FINAL_APP" || true
echo "Built $FINAL_APP"

# Install outside ~/Documents: an app that runs from Documents makes macOS ask for
# folder access and blocks the main thread until answered. The installed copy is the
# one LaunchServices opens for cra:// URLs.
INSTALL_APP="${CRA_INSTALL_DIR:-$HOME/Applications}/Cra.app"
mkdir -p "$(dirname "$INSTALL_APP")"
rsync -a --delete "$FINAL_APP/" "$INSTALL_APP/"
"$LSREGISTER" -u "$FINAL_APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
echo "Installed $INSTALL_APP"
