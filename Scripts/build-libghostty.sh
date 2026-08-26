#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

# Builds GhosttyKit.xcframework from the pinned Vendor/ghostty submodule using a
# pinned Zig toolchain downloaded into .tools/. Output:
#   Vendor/ghostty/macos/GhosttyKit.xcframework
# Bump ZIG_VERSION/ZIG_SHA256 together with the submodule commit; ghostty's
# build.zig.zon declares the minimum Zig it needs.
set -euo pipefail

ZIG_VERSION="0.16.0"
ZIG_SHA256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
ZIG_ARCH="aarch64-macos"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
ZIG_NAME="zig-${ZIG_ARCH}-${ZIG_VERSION}"
ZIG_DIR="$TOOLS/$ZIG_NAME"
ZIG="$ZIG_DIR/zig"
GHOSTTY="$ROOT/Vendor/ghostty"
OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"

if [[ ! -x "$ZIG" ]]; then
  mkdir -p "$TOOLS"
  tarball="$TOOLS/$ZIG_NAME.tar.xz"
  if [[ ! -f "$tarball" ]]; then
    echo "Downloading Zig $ZIG_VERSION..."
    curl -sSL -o "$tarball" "https://ziglang.org/download/$ZIG_VERSION/$ZIG_NAME.tar.xz"
  fi
  echo "$ZIG_SHA256  $tarball" | shasum -a 256 -c - >/dev/null
  tar -xJf "$tarball" -C "$TOOLS"
fi

if [[ ! -f "$GHOSTTY/build.zig" ]]; then
  echo "Vendor/ghostty is empty. Run: git submodule update --init" >&2
  exit 1
fi

echo "Using $("$ZIG" version) at $ZIG"
echo "Building libghostty ($OPTIMIZE) from $(git -C "$GHOSTTY" rev-parse --short HEAD)"
cd "$GHOSTTY"
# Sentry is off: libghostty would otherwise install a process-wide crash
# handler that writes minidumps (thread stacks included, so possibly a password
# in flight) under the app's Caches directory. Constellation ships no crash
# reporter; macOS crash logs are enough. Documented in the 0006 decision note.
"$ZIG" build \
  -Doptimize="$OPTIMIZE" \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Dsentry=false

echo "Built $GHOSTTY/macos/GhosttyKit.xcframework"
