#!/bin/bash
# Dev loop: debug build into build/CraDev.app, launch it, and rebuild + relaunch on
# every save under Sources/ or resources/.
#   scripts/dev.sh           watch and relaunch (Ctrl-C quits the app too)
#   scripts/dev.sh --once    build and launch once, logs in this terminal
#   CRA_DATA_DIR=<dir> scripts/dev.sh    use another profile (default build/dev-data)
# CraDev is its own app (executable name, bundle id, profile), so it runs next to the
# installed Cra, `killall Cra` elsewhere leaves it alone, and it never claims cra:// or
# http links. CEF is copied and signed once; each rebuild only swaps the Cra binaries,
# in a separate SwiftPM scratch dir so parallel `scripts/build.sh` runs don't collide.
# Unlike build.sh it signs without the hardened runtime, so a debugger can attach.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
NAME=CraDev
APP="$ROOT/build/$NAME.app"
SCRATCH="$ROOT/.build/dev"
STAMP="$SCRATCH/.dev-stamp"
export CRA_DATA_DIR="${CRA_DATA_DIR:-$ROOT/build/dev-data}"
PB=/usr/libexec/PlistBuddy
PID=""

# "<name suffix>|<plist suffix>", as in scripts/build.sh.
HELPERS=("|" " (Alerts)|.alerts" " (GPU)|.gpu" " (Plugin)|.plugin" " (Renderer)|.renderer")

bootstrap() {
  echo "Creating $APP (one time)..."
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
  sed -e "s/__VERSION__/0.0.0-dev/" -e "s/__BUILD__/0/" resources/Info.plist > "$APP/Contents/Info.plist"
  $PB -c "Set :CFBundleExecutable $NAME" -c "Set :CFBundleIdentifier io.github.rainmiku.cra.dev" \
      -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" \
      -c "Delete :CFBundleURLTypes" -c "Delete :CFBundleDocumentTypes" \
      -c "Delete :UTExportedTypeDeclarations" "$APP/Contents/Info.plist"
  echo -n "APPL????" > "$APP/Contents/PkgInfo"
  [ -f resources/AppIcon.icns ] && cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  local fw="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  cp -R "$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/"
  scripts/patch-cef-keychain.sh "$fw"
  find "$fw/Libraries" -name '*.dylib' -exec codesign --force --sign - {} \; 2>/dev/null
  codesign --force --sign - "$fw"
  for entry in "${HELPERS[@]}"; do
    local ns="${entry%%|*}" ps="${entry#*|}"
    local helper="$APP/Contents/Frameworks/$NAME Helper$ns.app"
    mkdir -p "$helper/Contents/MacOS"
    sed -e "s/__NAME_SUFFIX__/$ns/g" -e "s/__PLIST_SUFFIX__/$ps/g" -e "s/__VERSION__/0.0.0-dev/" -e "s/__BUILD__/0/" \
        -e "s/Cra Helper/$NAME Helper/g" -e "s/io\.github\.rainmiku\.cra\.helper/io.github.rainmiku.cra.dev.helper/" \
        resources/Helper-Info.plist > "$helper/Contents/Info.plist"
    echo -n "APPL????" > "$helper/Contents/PkgInfo"
  done
}

# Builds and swaps changed binaries into the bundle. Returns non-zero on a compile error.
build() {
  mkdir -p "$SCRATCH"
  touch "$STAMP"
  swift build -c debug --scratch-path "$SCRATCH" || return 1
  local bin
  bin="$(swift build -c debug --scratch-path "$SCRATCH" --show-bin-path)"
  # Re-bootstrap bundles made before CEF's Keychain item was renamed, or with another CEF version.
  local fw="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  [ -d "$APP/Contents/Frameworks/$NAME Helper.app" ] \
    && scripts/patch-cef-keychain.sh --check "$fw" \
    && cmp -s "$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework/Resources/Info.plist" "$fw/Resources/Info.plist" \
    || bootstrap
  [ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || cp -R "$bin/Sparkle.framework" "$APP/Contents/Frameworks/"
  for entry in "${HELPERS[@]}"; do
    local ns="${entry%%|*}" ent=resources/CraHelper.entitlements
    case "$ns" in " (GPU)"|" (Renderer)") ent=resources/CraHelperJIT.entitlements ;; esac
    local helper="$APP/Contents/Frameworks/$NAME Helper$ns.app"
    if ! cmp -s "$bin/CraHelper" "$helper/Contents/MacOS/$NAME Helper$ns"; then
      cp "$bin/CraHelper" "$helper/Contents/MacOS/$NAME Helper$ns"
      codesign --force --sign - --entitlements "$ent" "$helper"
    fi
  done
  cp "$bin/Cra" "$APP/Contents/MacOS/$NAME"
  for d in web brand blocklist; do
    [ -d "resources/$d" ] && rsync -a --delete "resources/$d/" "$APP/Contents/Resources/$d/"
  done
  codesign --force --sign - --entitlements resources/Cra.entitlements "$APP"
}

stop() {
  [ -n "$PID" ] || return 0
  if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$PID" 2>/dev/null || true
  fi
  wait "$PID" 2>/dev/null || true
  PID=""
}

launch() {
  "$APP/Contents/MacOS/$NAME" &
  PID=$!
  echo "▶ $NAME running (pid $PID, profile $CRA_DATA_DIR)"
}

changed() {
  [ -n "$(find Sources resources Package.swift -newer "$STAMP" -type f \
          \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -path 'resources/*' \) \
          -print -quit 2>/dev/null)" ]
}

scripts/fetch-cef.sh >/dev/null
trap 'stop; exit 0' INT TERM
trap stop EXIT

build || { [ "${1:-}" = "--once" ] && exit 1; echo "✗ Build failed; fix it and save to retry."; }
[ -x "$APP/Contents/MacOS/$NAME" ] && launch
if [ "${1:-}" = "--once" ]; then wait "$PID"; exit 0; fi

echo "Watching Sources/ and resources/ (Ctrl-C to quit)"
while true; do
  sleep 0.4
  changed || continue
  sleep 0.2  # let editors finish multi-file saves
  echo "↻ Change detected, rebuilding..."
  start=$(date +%s)
  if build; then
    stop
    launch
    echo "✓ Relaunched in $(( $(date +%s) - start ))s"
  else
    echo "✗ Build failed; $NAME keeps running the last good build."
  fi
done
