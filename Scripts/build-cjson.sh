#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

# Builds the pinned cJSON source release for arm64 macOS. WinPR's JSON layer
# wraps it, and FreeRDP's Entra ID sign-in and Azure Virtual Desktop transport
# need that layer. FreeRDP links the resulting static library into FreeRDPKit,
# so no cJSON dylib ships in the app. Bump CJSON_VERSION and CJSON_SHA256
# together.
set -euo pipefail

CJSON_VERSION="1.7.19"
CJSON_SHA256="7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562"
DEPLOYMENT_TARGET="15.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
VENDOR_BUILD="$ROOT/Vendor/build"
ARCHIVE_NAME="cjson-$CJSON_VERSION.tar.gz"
ARCHIVE="$TOOLS/$ARCHIVE_NAME"
SOURCE="$TOOLS/cJSON-$CJSON_VERSION"
PREFIX="$VENDOR_BUILD/cjson"
STAMP="$PREFIX/.constellation-build"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode command line tools are required" >&2; exit 1; }

sdk="$(xcrun --sdk macosx --show-sdk-path)"
toolchain="$(xcodebuild -version | tr '\n' ' ')"
script_hash="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
recipe="cJSON $CJSON_VERSION; sha256 $CJSON_SHA256; recipe $script_hash; macOS $DEPLOYMENT_TARGET; SDK $sdk; $toolchain"

if [[ -f "$PREFIX/lib/libcjson.a" && -f "$STAMP" ]] && [[ "$(<"$STAMP")" == "$recipe" ]]; then
  echo "Using cached cJSON $CJSON_VERSION at $PREFIX"
  exit 0
fi

mkdir -p "$TOOLS" "$VENDOR_BUILD"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading cJSON $CJSON_VERSION..."
  curl --fail --location --silent --show-error \
    --output "$ARCHIVE" \
    "https://github.com/DaveGamble/cJSON/archive/refs/tags/v$CJSON_VERSION.tar.gz"
fi
echo "$CJSON_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null

rm -rf "$SOURCE" "$PREFIX"
tar -xzf "$ARCHIVE" -C "$TOOLS"

echo "Building cJSON $CJSON_VERSION for arm64 macOS $DEPLOYMENT_TARGET..."
# cJSON still declares CMake 3.0 compatibility, which CMake 4 refuses without
# CMAKE_POLICY_VERSION_MINIMUM.
cmake -S "$SOURCE" -B "$SOURCE/build" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_CJSON_TEST=OFF \
  -DENABLE_CJSON_UTILS=OFF \
  -DENABLE_CUSTOM_COMPILER_FLAGS=OFF >/dev/null
cmake --build "$SOURCE/build" >/dev/null
cmake --install "$SOURCE/build" >/dev/null

cp "$SOURCE/LICENSE" "$PREFIX/LICENSE"
printf '%s\n' "$recipe" > "$STAMP"

echo "Built static cJSON library at $PREFIX"
