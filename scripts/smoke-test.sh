#!/bin/bash
# Launches a built Cra.app with a throwaway profile, opens a page that sets its
# title from JavaScript, and checks Chromium reports that title. Proves CEF
# initializes, starts the renderer helper and runs V8. Used by CI and the CEF
# update workflow.
#   scripts/smoke-test.sh [path/to/Cra.app]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(cd "${1:-build/Cra.app}" && pwd)"
EXPECTED="cra-smoke-42"
WORK="$(mktemp -d /tmp/cra-smoke.XXXXXX)"
LOG="$WORK/cra.log"
export CRA_DATA_DIR="$WORK/profile" CRA_COMMAND_FILE="$WORK/commands"

"$APP/Contents/MacOS/Cra" >"$LOG" 2>&1 &
PID=$!
cleanup() {
  kill -TERM "$PID" 2>/dev/null || true
  for _ in $(seq 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$PID" 2>/dev/null || true
  rm -rf "$WORK"
}
fail() {
  echo "Smoke test failed: $*" >&2
  echo "--- Cra output ---" >&2; tail -n 80 "$LOG" >&2 || true
  echo "--- chromium.log ---" >&2; tail -n 80 "$CRA_DATA_DIR/chromium.log" >&2 || true
  exit 1
}
trap cleanup EXIT

# Commands appended to CRA_COMMAND_FILE run like cra:// URLs (AppDelegate).
wait_for() {  # wait_for <seconds> <description> <command...>
  local secs="$1" what="$2"; shift 2
  for _ in $(seq $((secs * 2))); do
    kill -0 "$PID" 2>/dev/null || fail "Cra exited while waiting for $what"
    "$@" && return 0
    sleep 0.5
  done
  fail "timed out waiting for $what"
}
wait_for 60 "the command file watcher" test -f "$CRA_COMMAND_FILE"

# data: URL, so the check needs no network. JavaScript computes the title.
echo "cra://open?url=data:text/html,%3Cscript%3Edocument.title%3D'cra-smoke-'%2B(6*7)%3C/script%3E" >>"$CRA_COMMAND_FILE"

title_seen() {
  echo "cra://debug?bcdp=Target.getTargets" >>"$CRA_COMMAND_FILE"
  sleep 1
  grep -q "Cra bcdp Target.getTargets .*\"title\":\"$EXPECTED\"" "$LOG"
}
wait_for 90 "a page titled $EXPECTED" title_seen

CEF="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Frameworks/Chromium Embedded Framework.framework/Resources/Info.plist" 2>/dev/null || echo unknown)"
echo "Smoke test passed (Chromium Embedded Framework $CEF)"
