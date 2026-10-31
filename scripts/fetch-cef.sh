#!/bin/bash
# Downloads the pinned CEF binary distribution into vendor/cef and builds the
# C++ wrapper library. Safe to re-run; skips what is already there and replaces
# vendor/cef when the pinned version changes.
set -euo pipefail
cd "$(dirname "$0")/.."

# The pin is the version plus the SHA-1 that https://cef-builds.spotifycdn.com/index.json
# lists for its macosarm64 minimal tarball. .github/workflows/cef-update.yml bumps both.
# Overriding CEF_VERSION or CEF_ARCH requires the matching CEF_SHA1.
if { [ -n "${CEF_VERSION:-}" ] || [ -n "${CEF_ARCH:-}" ]; } && [ -z "${CEF_SHA1:-}" ]; then
  echo "Set CEF_SHA1 (from https://cef-builds.spotifycdn.com/index.json) when overriding CEF_VERSION or CEF_ARCH." >&2
  exit 1
fi
CEF_VERSION="${CEF_VERSION:-156.0.15+gcf671c0+chromium-156.0.8078.80}"
CEF_SHA1="${CEF_SHA1:-bcdd1877edb300b0fb91d8f71c0b14aae256cd0f}"
ARCH="${CEF_ARCH:-macosarm64}"
NAME="cef_binary_${CEF_VERSION}_${ARCH}_minimal"
URL="https://cef-builds.spotifycdn.com/${NAME}.tar.bz2"

mkdir -p vendor
# A different pinned version replaces vendor/cef, wrapper build included.
if [ -d vendor/cef ] && ! grep -qF "#define CEF_VERSION \"${CEF_VERSION}\"" vendor/cef/include/cef_version.h 2>/dev/null; then
  echo "vendor/cef is not CEF ${CEF_VERSION}; replacing it."
  rm -rf vendor/cef
fi
if [ ! -d vendor/cef/Release ]; then
  echo "Downloading ${NAME} (about 130 MB)..."
  mkdir -p vendor/cef-download
  curl -fL --progress-bar -o "vendor/cef-download/${NAME}.tar.bz2" "$URL"
  echo "${CEF_SHA1}  vendor/cef-download/${NAME}.tar.bz2" | shasum -a 1 -c - >/dev/null \
    || { echo "SHA-1 mismatch for ${NAME}.tar.bz2; refusing to use it." >&2; rm -rf vendor/cef-download; exit 1; }
  tar -xjf "vendor/cef-download/${NAME}.tar.bz2" -C vendor/cef-download
  rm -rf vendor/cef
  mv "vendor/cef-download/${NAME}" vendor/cef
  rm -rf vendor/cef-download
fi

if [ ! -f vendor/cef/build/libcef_dll_wrapper/libcef_dll_wrapper.a ]; then
  echo "Building libcef_dll_wrapper..."
  cmake -S vendor/cef -B vendor/cef/build -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=ON \
    -DCMAKE_OSX_ARCHITECTURES=arm64 > vendor/cef/build-configure.log
  cmake --build vendor/cef/build --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)" > vendor/cef/build-wrapper.log
fi
echo "CEF ready: vendor/cef"
