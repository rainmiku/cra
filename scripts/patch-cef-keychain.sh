#!/bin/bash
# Gives Cra its own Keychain item for Chromium's cookie and password key. CEF
# hard-codes Chromium's item ("Chromium Safe Storage", account "Chromium"), which
# Chromium and every other CEF app share. The new name has the same length, so
# nothing else in the binary moves. SafeStorage.swift uses the same name.
# Run on a copy of the framework before signing it.
#   scripts/patch-cef-keychain.sh <Chromium Embedded Framework.framework>
#   scripts/patch-cef-keychain.sh --check <framework>   exit 0 when already patched
set -euo pipefail
CHECK=""
[ "${1:-}" = "--check" ] && { CHECK=1; shift; }
BIN="$1/Chromium Embedded Framework"
if LC_ALL=C grep -qaF "Cra Data Safe Storage" "$BIN"; then exit 0; fi
[ -n "$CHECK" ] && exit 1
perl -0777 -pi -e '$n = s/Chromium Safe Storage\0Chromium\0/Cra Data Safe Storage\0Chromium\0/g; END { $? = $n == 1 ? 0 : 1 }' "$BIN" \
  || { echo "CEF's Keychain item name not found in $BIN; update scripts/patch-cef-keychain.sh and SafeStorage.swift." >&2; exit 1; }
